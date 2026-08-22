## Release build

Release builds use Xcode 26 on macOS 26 and the app's normal Swift package
dependencies. The release is a normal Xcode archive with no native model build steps.

```shell
./notarize_app.sh $CODE_SIGN_IDENTITY 
```

Example:
```shell
./notarize_app.sh "Developer ID Application: AAAA BBBB (XXXXX)" 
```

The default Apple Speech backend is on-device after its language asset is
installed. The optional OpenAI backend uploads stopped recordings to
`gpt-transcribe`.
