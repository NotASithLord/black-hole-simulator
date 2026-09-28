# Cinematic presentation layer

This guide describes the native presentation. The browser uses the same
transport/presentation separation, with simpler material and no fluid solver;
its [Motion first defaults](../Browser/README.md) also disable glare.

The Radiant appearance is a presentation layer over the same Kerr transport
solution used by Scientific.  It is designed to make the view feel more
dramatic and legible at a glance while keeping a clear boundary between what
is calculated and what is art-directed.

## What remains calculated

- Kerr geodesics, the observer tetrad, redshift, disk intersections, path
  delays, occultation, and the Page--Thorne radial flux table are unchanged.
- A faint celestial point can be drawn only after the same integrated ray is
  classified as escaped. Its position comes from that ray's finite escape
  coordinates, never from a screen-space ring or backdrop.
- The disk material's dominant phase follows the radius-dependent Kerr
  angular velocity.  Playback rate changes the labelled source clock only;
  it cannot change a ray's redshift, travel delay, or trajectory.
- Glow is sourced exclusively from the resolved HDR transport image.  No
  photon ring, highlight, or shadow edge is painted into the result.

## What is intentionally cinematic

- A warm emission palette, bounded co-moving brightness variation, and
  evolving dye detail make the material more readable in motion.
- A normalized multiscale glare response, highlight halo, restrained aperture
  streak, filmic luminance curve, and SDR gamut compression shape the
  presentation after transport has been rendered.
- The tiny static celestial field is procedural and deliberately sparse. It
  supplies environmental depth, not a real star catalogue, a sky survey, or
  a model of a black-hole environment.
- The optional slow observer orbit adds a composed camera movement. It is
  independent of the disk's source clock and is not an observer trajectory
  model. Each position is retraced rather than interpolating the light field,
  so it is intentionally an explicit, potentially expensive control.

These choices do not claim a plasma temperature, lens measurement, GRMHD
history, or exact reproduction of any film image.  Setting material
fluctuation, fluid detail, and lens glow to zero restores a presentation that
is correspondingly closer to the Scientific reference; selecting Scientific
removes the Radiant palette and photographic response altogether.

## Visual review checklist

Use this short checklist whenever a presentation control is changed:

1. The shadow boundary and lensed disk topology must match the geometry-only
   render; flare may broaden bright regions but must never create a new arc.
2. With the source paused, the image must be stable: no random pixel flicker,
   pulsing black background, or changing silhouette.
3. With material playback enabled, fine structure should shear faster inward
   and remain attached to the disk rather than rotating as a flat screen
   texture.
4. Brightness variation must remain restrained: it should reveal material,
   not invert the calculated Doppler-dominant side or wash out the central
   shadow.
5. The Scientific appearance must still produce no warm palette remap,
   photographic glare, fluid texture, or camera-art response.

The automated appearance and rotation checks complement this review.  They
verify finite/bounded output, luminance preservation before material
modulation, transport-cache equivalence, stable scientific output, and
radius-dependent material evolution.  A visual review is still useful for
detecting an aesthetically excessive but numerically valid response.
