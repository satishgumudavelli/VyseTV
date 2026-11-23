package com.vyse.vyse_tv.network

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketAddress
import java.net.URI
import java.net.URL
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * WARP, Anti-DPI and the player proxy (specs/001-warp-doh-anti-dpi/contracts/native-channel.md), channel `vyse/network`.
 *
 * WARP is usque (`libusque.so`, a Cloudflare WARP client with a local HTTP proxy), Anti-DPI is ByeDPI (`libciadpi.so`, a local SOCKS5
 * proxy). Both are programs in the app's native-library folder (unpacked on install, like the TorrServer binary), started as child
 * processes that listen on 127.0.0.1 only. Nothing here touches other apps or the device's network settings.
 */
class NetworkModesPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel
  private lateinit var context: Context
  private val io = Executors.newCachedThreadPool()
  private val main = Handler(Looper.getMainLooper())
  private val lock = Any()

  private class Running(val process: Process, val port: Int, val args: String)

  @Volatile private var warp: Running? = null
  @Volatile private var antiDpi: Running? = null
  @Volatile private var stopping = false

  private class Failure(val code: String, message: String) : Exception(message)

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "vyse/network")
    channel.setMethodCallHandler(this)
    io.execute { killLeftovers() } // a program left by a crashed earlier run would hold a port and a tunnel
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    stopAll()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "capabilities" -> result.success(mapOf("warp" to binary(USQUE).canExecute(), "antiDpi" to binary(CIADPI).canExecute(), "dns" to true))
      "status" -> result.success(mapOf("warp" to status(warp), "antiDpi" to status(antiDpi)))
      "setProxy" -> {
        setProxy(call.argument<String>("host"), call.argument<Int>("port"))
        result.success(mapOf<String, Any>())
      }
      "stopWarp" -> io.execute { stopWarp(); main.post { result.success(mapOf<String, Any>()) } }
      "stopAntiDpi" -> io.execute { stopAntiDpi(); main.post { result.success(mapOf<String, Any>()) } }
      "startWarp" -> runAsync(result) { mapOf("port" to startWarp()) }
      "startAntiDpi" -> {
        val args = call.argument<String>("args") ?: ""
        runAsync(result) { mapOf("port" to startAntiDpi(args)) }
      }
      else -> result.notImplemented()
    }
  }

  private fun runAsync(result: MethodChannel.Result, block: () -> Map<String, Any>) {
    io.execute {
      try {
        val r = block()
        main.post { result.success(r) }
      } catch (f: Failure) {
        main.post { result.error(f.code, f.message, null) }
      } catch (t: Throwable) {
        Log.w(TAG, "network mode failed", t)
        main.post { result.error("FAILED", t.message ?: t.javaClass.simpleName, null) }
      }
    }
  }

  private fun status(r: Running?): Map<String, Any?> = mapOf("running" to (r != null && r.process.isAlive), "port" to r?.port)

  // ── the programs ──

  private fun binary(name: String) = File(context.applicationInfo.nativeLibraryDir, name)

  private fun freePort(): Int = ServerSocket(0, 0, InetAddress.getByName("127.0.0.1")).use { it.localPort }

  private fun killLeftovers() {
    for (n in listOf(USQUE, CIADPI)) {
      try {
        Runtime.getRuntime().exec(arrayOf("sh", "-c", "pkill -f $n || killall $n")).waitFor(1, TimeUnit.SECONDS)
      } catch (_: Exception) {}
    }
  }

  private fun stopAll() {
    stopWarp()
    stopAntiDpi()
    setProxy(null, null)
  }

  private fun kill(r: Running?) {
    if (r == null) return
    try {
      r.process.destroy()
      if (!r.process.waitFor(2, TimeUnit.SECONDS)) r.process.destroyForcibly()
    } catch (_: Exception) {}
  }

  private fun watch(mode: String, r: Running) {
    Thread {
      val code = try { r.process.waitFor() } catch (_: InterruptedException) { return@Thread }
      val current = if (mode == "warp") warp else antiDpi
      if (current === r && !stopping) {
        if (mode == "warp") warp = null else antiDpi = null
        main.post { channel.invokeMethod("onModeEvent", mapOf("mode" to mode, "state" to "exited", "reason" to "the program stopped (exit code $code)")) }
      }
    }.apply { isDaemon = true }.start()
  }

  /** Starts [command] and waits until [ready] says it listens or it dies; returns its last output lines when it did not. */
  private class Launched(val process: Process?, val failTail: String, val tail: List<String>)

  private fun launch(command: List<String>, dir: File?, waitMs: Long, ready: (Process, List<String>) -> Boolean): Launched {
    val pb = ProcessBuilder(command).redirectErrorStream(true)
    if (dir != null) pb.directory(dir)
    val p = pb.start()
    val tail = java.util.Collections.synchronizedList(ArrayList<String>())
    val listening = java.util.concurrent.atomic.AtomicBoolean(false)
    Thread {
      try {
        p.inputStream.bufferedReader().forEachLine { line ->
          tail.add(line.take(200))
          if (tail.size > 6) tail.removeAt(0)
          if (line.contains("listening on", ignoreCase = true)) listening.set(true)
        }
      } catch (_: Exception) {}
    }.apply { isDaemon = true }.start()
    val deadline = System.currentTimeMillis() + waitMs
    while (System.currentTimeMillis() < deadline) {
      if (!p.isAlive) return Launched(null, tail.joinToString(" | "), tail)
      if (listening.get() || ready(p, tail)) return Launched(p, "", tail)
      Thread.sleep(80)
    }
    return if (p.isAlive && ready(p, tail)) Launched(p, "", tail) else { p.destroyForcibly(); Launched(null, tail.joinToString(" | "), tail) }
  }

  // ── WARP ──

  private fun warpDir(): File = File(context.filesDir, "warp").apply { mkdirs() }

  private fun startWarp(): Int = synchronized(lock) {
    warp?.let { if (it.process.isAlive) return it.port }
    val bin = binary(USQUE)
    if (!bin.canExecute()) throw Failure("WARP_NO_BINARY", "WARP is not available on this device")
    val config = File(warpDir(), "config.json")
    if (!config.exists() || config.length() == 0L) {
      try {
        register(config)
      } catch (e: Exception) {
        Log.w(TAG, "WARP registration failed", e)
        throw Failure("WARP_REGISTRATION_FAILED", "Could not register with Cloudflare WARP: ${e.message ?: e.javaClass.simpleName}")
      }
    }
    stopping = false
    val why = ArrayList<String>()
    // HTTP/3 first, HTTP/2 for a network that blocks UDP 443. (No mode that switches off certificate pinning.)
    for ((label, extra) in listOf("HTTP/3" to emptyList<String>(), "HTTP/2" to listOf("--http2"))) {
      val port = freePort()
      val cmd = listOf(bin.absolutePath, "-c", config.absolutePath, "http-proxy", "-b", "127.0.0.1", "-p", port.toString(), "-d", "1.1.1.1", "-d", "8.8.8.8") + extra
      val l = try { launch(cmd, warpDir(), 3000) { _, _ -> false } } catch (e: Exception) { throw Failure("WARP_START_FAILED", "WARP did not start: ${e.message}") }
      val p = l.process
      if (p == null) { why.add("$label: the program stopped at once (${l.failTail.ifEmpty { "no output" }})"); continue }
      val check = viaWarp(port)
      if (check == null) {
        val r = Running(p, port, extra.joinToString(" "))
        warp = r
        watch("warp", r)
        return port
      }
      Log.w(TAG, "WARP $label check failed: $check; program said: ${l.tail.joinToString(" | ")}")
      why.add("$label: $check; the program said: ${l.tail.takeLast(2).joinToString(" | ").ifEmpty { "nothing" }}")
      p.destroyForcibly()
    }
    val lastWhy = why.joinToString("; ")
    throw Failure("WARP_START_FAILED", "WARP did not connect: $lastWhy")
  }

  /** null when a request through the local proxy really leaves through WARP (Cloudflare's trace says `warp=on`); else why not. */
  private fun viaWarp(port: Int): String? = try {
    val c = URL(TRACE_URL).openConnection(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", port))) as HttpURLConnection
    c.connectTimeout = 8000
    c.readTimeout = 8000
    val body = c.inputStream.bufferedReader().use { it.readText() }
    if (body.contains("warp=on") || body.contains("warp=plus")) null else "Cloudflare answered but the traffic did not go through WARP"
  } catch (e: Exception) { "no answer through the tunnel (${e.javaClass.simpleName}: ${e.message})" }

  private fun stopWarp() {
    synchronized(lock) {
      stopping = true
      val r = warp
      warp = null
      kill(r)
      stopping = false
    }
  }

  private fun register(config: File) {
    val random = SecureRandom()
    val kp = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("prime256v1")) }.generateKeyPair()
    val sec1 = sec1PrivateKey(kp)
    val masquePub = Base64.encodeToString(kp.public.encoded, Base64.NO_WRAP)
    val wgKey = Base64.encodeToString(ByteArray(32).also { random.nextBytes(it) }, Base64.NO_WRAP)
    val serial = ByteArray(8).also { random.nextBytes(it) }.joinToString("") { "%02x".format(it) }
    val tos = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date())

    val reg = JSONObject().put("key", wgKey).put("install_id", "").put("fcm_token", "").put("tos", tos).put("model", "PC")
      .put("serial_number", serial).put("os_version", "").put("key_type", "curve25519").put("tunnel_type", "wireguard").put("locale", "en_US")
    val first = api("POST", "$API/reg", reg, null)
    val id = first.getString("id")
    val token = first.getString("token")
    val enroll = JSONObject().put("key", masquePub).put("key_type", "secp256r1").put("tunnel_type", "masque")
    val res = api("PATCH", "$API/reg/$id", enroll, token)
    val cfg = res.getJSONObject("config")
    val peer = cfg.getJSONArray("peers").getJSONObject(0)
    val endpoint = peer.getJSONObject("endpoint")
    val addr = cfg.getJSONObject("interface").getJSONObject("addresses")
    val out = JSONObject()
      .put("private_key", sec1)
      .put("endpoint_v4", endpoint.getString("v4").removeSuffix(":0"))
      .put("endpoint_v6", endpoint.getString("v6").removePrefix("[").removeSuffix("]:0"))
      .put("endpoint_h2_v4", "162.159.198.2")
      .put("endpoint_h2_v6", "")
      .put("endpoint_pub_key", peer.getString("public_key"))
      .put("id", res.getString("id"))
      .put("access_token", token)
      .put("ipv4", addr.getString("v4"))
      .put("ipv6", addr.getString("v6"))
    val tmp = File(config.parentFile, "config.json.tmp")
    tmp.writeText(out.toString(2))
    if (!tmp.renameTo(config)) throw IOException("cannot save the WARP configuration")
  }

  private fun api(method: String, url: String, body: JSONObject, bearer: String?): JSONObject {
    val c = URL(url).openConnection() as HttpURLConnection
    try {
      c.requestMethod = method
      c.connectTimeout = 15000
      c.readTimeout = 15000
      c.doOutput = true
      c.setRequestProperty("User-Agent", "WARP for Android")
      c.setRequestProperty("CF-Client-Version", "a-6.35-4471")
      c.setRequestProperty("Content-Type", "application/json; charset=UTF-8")
      if (bearer != null) c.setRequestProperty("Authorization", "Bearer $bearer")
      c.outputStream.use { it.write(body.toString().toByteArray()) }
      val code = c.responseCode
      if (code !in 200..299) throw IOException("HTTP $code")
      val json = JSONObject(c.inputStream.bufferedReader().use { it.readText() })
      return if (json.has("result") && !json.isNull("result")) json.getJSONObject("result") else json
    } finally {
      c.disconnect()
    }
  }

  private fun fixed(bi: java.math.BigInteger, len: Int): ByteArray {
    val raw = bi.toByteArray()
    if (raw.size == len) return raw
    val out = ByteArray(len)
    if (raw.size > len) System.arraycopy(raw, raw.size - len, out, 0, len) else System.arraycopy(raw, 0, out, len - raw.size, raw.size)
    return out
  }

  /** The EC private key as a SEC1 structure (what usque reads), base64. */
  private fun sec1PrivateKey(kp: KeyPair): String {
    val priv = kp.private as ECPrivateKey
    val pub = kp.public as ECPublicKey
    val uncompressed = byteArrayOf(0x04) + fixed(pub.w.affineX, 32) + fixed(pub.w.affineY, 32)
    val der = byteArrayOf(0x30, 0x77, 0x02, 0x01, 0x01, 0x04, 0x20) + fixed(priv.s, 32) +
      byteArrayOf(0xa0.toByte(), 0x0a, 0x06, 0x08, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x03, 0x01, 0x07, 0xa1.toByte(), 0x44, 0x03, 0x42, 0x00) + uncompressed
    return Base64.encodeToString(der, Base64.NO_WRAP)
  }

  // ── Anti-DPI ──

  private fun startAntiDpi(args: String): Int = synchronized(lock) {
    val tokens = args.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
    for (t in tokens) {
      if (t == "-i" || t == "-p" || t == "-I" || t == "--ip" || t == "--port" || t == "--conn-ip" || t.startsWith("--ip=") || t.startsWith("--port=") || t.startsWith("--conn-ip=") ||
        (t.length > 2 && t.startsWith("-") && !t.startsWith("--") && t[1] in "ipI")) {
        throw Failure("DPI_BAD_ARGS", "The address and port are set by the app: remove ${t.substringBefore('=')}")
      }
    }
    val canonical = tokens.joinToString(" ")
    antiDpi?.let { if (it.process.isAlive) { if (it.args == canonical) return it.port; stopAntiDpiLocked() } }
    val bin = binary(CIADPI)
    if (!bin.canExecute()) throw Failure("DPI_NO_BINARY", "Anti-DPI is not available on this device")
    val port = freePort()
    stopping = false
    val l = try {
      launch(listOf(bin.absolutePath, "-i", "127.0.0.1", "-p", port.toString()) + tokens, null, 4000) { _, _ -> accepts(port) }
    } catch (e: Exception) {
      throw Failure("DPI_START_FAILED", "Anti-DPI did not start: ${e.message}")
    }
    val p = l.process
    val tail = l.failTail
    if (p == null) throw Failure(if (tail.isEmpty()) "DPI_START_FAILED" else "DPI_BAD_ARGS", "Anti-DPI did not start${if (tail.isEmpty()) "" else ": $tail"}")
    val r = Running(p, port, canonical)
    antiDpi = r
    watch("antiDpi", r)
    return port
  }

  private fun accepts(port: Int): Boolean = try { Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 150); true } } catch (_: Exception) { false }

  private fun stopAntiDpi() = synchronized(lock) { stopAntiDpiLocked() }

  private fun stopAntiDpiLocked() {
    stopping = true
    val r = antiDpi
    antiDpi = null
    kill(r)
    stopping = false
  }

  // ── the players' proxy ──

  private var previousSelector: ProxySelector? = null

  /**
   * Points the JVM's default proxy selector (ExoPlayer's HttpURLConnection reads it) at the local gateway, or restores it. This device
   * and its local network always go DIRECT, so TorrServer and casting are not affected.
   */
  private fun setProxy(host: String?, port: Int?) {
    synchronized(lock) {
      if (host == null || port == null) {
        proxyActive = false
        previousSelector?.let { ProxySelector.setDefault(it) }
        previousSelector = null
        return
      }
      if (previousSelector == null) previousSelector = ProxySelector.getDefault()
      val gateway = Proxy(Proxy.Type.HTTP, InetSocketAddress(host, port))
      ProxySelector.setDefault(object : ProxySelector() {
        override fun select(uri: URI?): List<Proxy> = if (uri == null || isLocal(uri.host)) listOf(Proxy.NO_PROXY) else listOf(gateway)
        override fun connectFailed(uri: URI?, sa: SocketAddress?, ioe: IOException?) {}
      })
      proxyActive = true
    }
  }

  companion object {
    private const val TAG = "NetworkModes"
    private const val USQUE = "libusque.so"
    private const val CIADPI = "libciadpi.so"
    private const val API = "https://api.cloudflareclient.com/v0a4471"
    private const val TRACE_URL = "https://www.cloudflare.com/cdn-cgi/trace"

    /** True while the players must go through the local gateway (ExoPlayer then skips Cronet, which cannot use a proxy selector). */
    @Volatile var proxyActive = false

    /** This device or its local network: never sent through a mode. */
    fun isLocal(host: String?): Boolean {
      if (host.isNullOrEmpty()) return true
      val h = host.lowercase().removeSurrounding("[", "]")
      if (h == "localhost" || h.endsWith(".localhost") || h.endsWith(".local") || h.endsWith(".lan") || h.endsWith(".home.arpa")) return true
      val literal = Regex("^[0-9.]+$").matches(h) || h.contains(':')
      if (!literal) return false
      return try {
        val a = InetAddress.getByName(h) // a literal: no lookup happens
        val b = a.address
        a.isLoopbackAddress || a.isLinkLocalAddress || a.isAnyLocalAddress || a.isMulticastAddress || a.isSiteLocalAddress ||
          (b.size == 4 && (b[0].toInt() and 255) == 100 && (b[1].toInt() and 255) in 64..127) ||
          (b.size == 16 && (b[0].toInt() and 0xfe) == 0xfc)
      } catch (_: Exception) { true }
    }
  }
}
