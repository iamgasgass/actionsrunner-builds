// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

// The byte counts the camera offer (photo_dimensions.hpp), the system camera
// (apple/camera_capture.mm) and the host memory reserve (device/camera/
// camera_tiers.hpp) share: the NV12 capture buffer, and the working storage the
// system camera holds for a JPEG still. It stands alone because the
// application's runtime loader compiles the reserve without the platform's
// include path.

#include <cstdint>

namespace uml::platform {

// The bytes of an NV12 frame of `width` by `height` in a capture buffer whose
// rows are padded to `rowAlignment` bytes (zero or one: not padded): the luma
// rows and the chroma rows, which are half as many, rounded up.
[[nodiscard]] constexpr std::uint64_t alignedFrameBytes(std::uint32_t width, std::uint32_t height, std::uint32_t rowAlignment) noexcept
{
    const std::uint64_t alignment = rowAlignment != 0 ? rowAlignment : 1;
    const std::uint64_t pitch = (std::uint64_t(width) + alignment - 1) / alignment * alignment;
    return pitch * (std::uint64_t(height) + (std::uint64_t(height) + 1) / 2);
}

// The working storage, in bytes for each pixel of a JPEG still, that the
// system's camera holds while it makes the picture, beyond the encoded file the
// reserve counts for the capture: the photo pipeline's own buffers. It is the
// most the process footprint rose over what the reserve counts for a capture of
// 12 MP stills taken with the preview running, on an iPad mini 6, in two
// sessions: 17 MiB, 1.5 bytes a pixel, counted as 2 for headroom (a third more).
inline constexpr std::uint32_t systemCameraStillWorkingBytesPerPixel = 2;

} // namespace uml::platform
