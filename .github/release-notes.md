**Install from the zip**

```sh
shasum -a 256 -c SHA256SUMS             # verify the download against the published manifest
unzip blescan-*-macos-universal.zip
xattr -d com.apple.quarantine blescan   # the binary is ad-hoc signed; Gatekeeper quarantines downloads
mv blescan ~/.bin/                      # or anywhere on your PATH
blescan --diag                          # first run triggers the Bluetooth permission prompt
```

Universal binary (Apple Silicon + Intel), macOS 12 or later. Building from source with
`make install` skips the quarantine step and, with a personal signing certificate, keeps the
Bluetooth grant across upgrades — see the README.
