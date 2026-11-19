package com.vyse.player.exoplayer

/**
 * VyseTV: when a video decoder that has shown nothing yet is called hung.
 *
 * A hung decoder takes input and gives no picture (Dolby Vision profile 7 on a chip that accepts
 * the format and never decodes it). The check for it used to be one look, five seconds after the
 * decoder was created: any input queued and no output meant "hung", and the video went to mpv.
 *
 * That clock started too early for a slow host. The decoder is created as soon as the file's
 * header is read, before any of the picture has arrived, and on a link that takes several seconds
 * to answer each request the first frames can arrive four and a half seconds in: at five seconds
 * the decoder holds one or two of them, has not had time to give a picture, and is called hung.
 * (A tester's TV took 4, 7 and 21 seconds to the first frame of the same films in another app
 * that plays them with the same decoder.) The one look also missed a real hang whose input came
 * after the five seconds.
 *
 * So the clock counts only while the decoder has something to work on: input queued, and media
 * waiting ahead of the position, at least what the load control itself wants before it starts
 * playing. Short of that the wait is the network's and the loader's business, as in
 * [BufferingStallPolicy], and the clock starts over. Looked at every second until the first
 * frame shows.
 */
internal object DecoderHangPolicy {

  /** How often the decoder is looked at until its first frame. */
  const val CHECK_INTERVAL_MS = 1_000L

  /** How long a decoder may hold input, with media waiting, and still show nothing. */
  const val HANG_TIMEOUT_MS = 5_000L

  /** Media waiting ahead of the position before the decoder is the one holding the start up. */
  const val MIN_BUFFER_AHEAD_MS: Long = LoadControlPolicy.BUFFER_FOR_PLAYBACK_MS.toLong()

  enum class Verdict {
    /** It has decoded something: nothing to watch for. */
    DECODING,

    /** Nothing, or too little, has reached it yet: the clock does not run. */
    STARVED,

    /** It has what it needs and has shown nothing, but not for long enough yet. */
    WAITING,

    /** It has had what it needs for [HANG_TIMEOUT_MS] and has shown nothing. */
    HUNG
  }

  /** Whether the decoder has enough to be expected to give a picture. */
  fun isFed(inputQueued: Int, bufferedAheadMs: Long): Boolean = inputQueued > 0 && bufferedAheadMs >= MIN_BUFFER_AHEAD_MS

  /**
   * @param fedForMs how long [isFed] has held without a break; 0 when it does not hold now.
   * @param outputTotal frames rendered, skipped and dropped so far.
   */
  fun evaluate(fedForMs: Long, inputQueued: Int, outputTotal: Int, bufferedAheadMs: Long): Verdict = when {
    outputTotal > 0 -> Verdict.DECODING
    !isFed(inputQueued, bufferedAheadMs) -> Verdict.STARVED
    fedForMs < HANG_TIMEOUT_MS -> Verdict.WAITING
    else -> Verdict.HUNG
  }
}
