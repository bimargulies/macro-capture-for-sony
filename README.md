# Macro Capture for Sony

An independent macOS app for tethered macro photography with a Sony A7R V (ILCE-7RM5). It shows live view, fires the shutter, transfers each raw file to the Mac, and writes descriptions and stack markers to XMP sidecars. It never modifies an ARW file.

**This project is not affiliated with, endorsed by, sponsored by, or supported by Sony.** "Sony" appears in the name only to identify the cameras the app works with.

## Requirements

- A Mac running a macOS version supported by the SDK (14.1 or later for SDK v2.02.00).
- A Sony A7R V. Other cameras are untested.
- Xcode command-line tools and ExifTool (`brew install exiftool`).
- Sony's Camera Remote SDK v2.02.00 for macOS, which you must get from Sony.

## The Sony SDK is not included

This repository contains no part of Sony's Camera Remote SDK: no libraries, headers, sample code, or documentation. Apply for the SDK on [Sony's Camera Remote SDK page](https://support.d-imaging.sony.co.jp/app/sdk/en/index.html) and accept [Sony's license agreement](https://support.d-imaging.sony.co.jp/app/sdk/licenseagreement/en.html) yourself.

Unpack the package and its `SimpleCli.zip` so this path exists:

```text
third_party/CrSDK_v2.02.00_20260610a_Mac/unpacked/SimpleCli
```

`third_party/` is ignored by git. Please do not commit the SDK or open pull requests containing any part of it.

## Build and run

```sh
cd app
swift test
./bundle.sh
open "build/Macro Capture for Sony.app"
```

Quit Adobe Bridge before running the app, because it can hold the camera connection.

## Distributing a built app

The MIT license below covers only the code in this repository. A built app also contains Sony's SDK libraries, under Sony's terms, and ExifTool, under its own license. If you distribute a build, you are responsible for complying with those terms, including the obligations Sony's agreement places on developers toward their end users.

## License

The code in this repository is available under the [MIT License](LICENSE). That license grants no rights to Sony's SDK or to any trademark.

## Trademarks

Sony is a trademark or registered trademark of Sony Corporation. Mac and macOS are registered trademarks of Apple Inc. Adobe Bridge is a trademark of Adobe. All other trademarks and copyrights are the property of their respective owners.
