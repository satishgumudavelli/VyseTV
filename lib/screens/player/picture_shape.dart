import 'dart:ui' show Size;

/// The picture's shape on the screen (the player's More > Picture > Aspect ratio, and on a phone
/// a button of its own).
///
/// Fit shows the whole picture at its own shape, with black bars where the screen is another
/// shape; Fill crops it to cover the screen; Stretch pulls it to the screen's shape. The three
/// fixed shapes force a picture to be shown as 16:9, 4:3 or 21:9, for a file that says the wrong
/// shape (an old show squeezed into a wide frame).
///
/// How each engine is told, after upstream's player: mpv crops with `panscan` and changes the
/// shape with `video-aspect-override` (the app's own libmpv, asked: 4:3 on a 640 by 360 picture
/// makes it 640 by 480, playing or paused); Android's Media3 player crops and stretches its
/// picture frame (`setBoxFitMode`) and takes the forced shape from the same mpv property, which
/// its plugin passes on (and keeps for the mpv it may hand a video to).
enum PictureShape {
  fit('fit', 'Fit'),
  fill('fill', 'Fill'),
  stretch('stretch', 'Stretch'),
  wide('16:9', '16:9'),
  square('4:3', '4:3'),
  cinema('21:9', '21:9');

  const PictureShape(this.id, this.label);

  /// What is kept in Settings, and for the forced shapes what mpv is given.
  final String id;
  final String label;

  /// Fit, Fill and Stretch are remembered on this device: they are about its screen. A forced
  /// shape is about one video, and lasts until the player closes.
  bool get kept => index <= PictureShape.stretch.index;

  /// The remembered shape, from what Settings holds; Fit for anything else.
  static PictureShape remembered(String id) => values.firstWhere((s) => s.kept && s.id == id, orElse: () => fit);

  /// What the phone's button moves on to: Fit, Fill, Stretch and round again (a forced shape
  /// goes back to Fit).
  PictureShape get next => switch (this) {
    fit => fill,
    fill => stretch,
    _ => fit,
  };

  /// Media3's picture frame: 0 shows it whole, 1 crops it to the screen, 2 stretches it.
  int get boxFit => switch (this) {
    fill => 1,
    stretch => 2,
    _ => 0,
  };

  /// mpv's `panscan`: 1 crops the picture until it covers the screen.
  String get panscan => this == fill ? '1.0' : '0';

  /// mpv's `video-aspect-override` for a picture drawn in [box]: the forced shape; for Stretch the
  /// box's own shape (which pulls the picture to it); `no` for the picture's own shape.
  String aspectOverride(Size? box) {
    switch (this) {
      case wide || square || cinema:
        return id;
      case stretch when box != null && box.width > 0 && box.height > 0:
        return (box.width / box.height).toStringAsFixed(4);
      default:
        return 'no';
    }
  }

  /// Subtitles kept on the screen rather than on a picture that runs off it.
  bool forceMargins({required int zoomPercent}) => this == fill || zoomPercent > 100;
}
