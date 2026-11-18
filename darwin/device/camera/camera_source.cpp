// SPDX-License-Identifier: GPL-2.0-or-later
#include "camera_source.hpp"

#include "camera_authorization.hpp"

#if UML_CAMERA_SOURCE_HAS_SYNTHETIC
#include "synthetic_camera/synthetic_camera.hpp"
#endif

#include <cstdlib>
#include <stdexcept>

namespace uml::camera {

bool syntheticCameraAvailable() noexcept
{
    return UML_CAMERA_SOURCE_HAS_SYNTHETIC != 0;
}

bool hostCameraPermissionGranted()
{
    return uml::platform::makeAppleCameraAuthorization()->permission() ==
           uml::platform::CameraPermission::granted;
}

CameraSourceHandle makeSyntheticCameraSource([[maybe_unused]] SyntheticProfile profile)
{
#if UML_CAMERA_SOURCE_HAS_SYNTHETIC
    uml::platform::SyntheticCameraOptions options;
    switch (profile) {
    case SyntheticProfile::phone:
        options.profile = uml::platform::SyntheticCameraProfile::phone;
        break;
    case SyntheticProfile::tablet:
        options.profile = uml::platform::SyntheticCameraProfile::tablet;
        break;
    case SyntheticProfile::laptop:
        options.profile = uml::platform::SyntheticCameraProfile::laptop;
        break;
    }
    if (const char* control = std::getenv(syntheticControlVariable); control != nullptr) options.controlPath = control;
    return uml::platform::makeSyntheticCamera(options);
#else
    throw std::runtime_error("the synthetic camera is not part of this build");
#endif
}

CameraSourceHandle makeHostCameraSource()
{
    return uml::platform::makeAppleCamera();
}

} // namespace uml::camera
