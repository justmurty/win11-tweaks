# Mouse pointer

`cursors-windows11-light.zip` holds **MSUHost Cursors**: **Windows 11 Cursors Concept (light)** by
**JepriCreations** (DeviantArt: jepricreations / rosea92), licensed under
[Creative Commons Attribution-NonCommercial-NoDerivatives 3.0](https://creativecommons.org/licenses/by-nc-nd/3.0/).
The 17 cursor files are unchanged; only their `Install.inf` is left out. The script installs them
itself instead: the files go to `%SystemRoot%\Cursors\Windows_11_light`, the scheme is
"MSUHost Cursors", and the theme "MSUHost (dark)" (the Windows (dark)
theme with these cursors) becomes the current theme.

The script uses the zip only when its SHA-256 matches the one in `$script:Cursors`. If you replace
the zip, update that hash too.
