# Membrane HLS Plugin
Plugin providing a `Membrane.HLS.Source` element for HTTP Live Streaming (HLS)
playlist files.

This element is used in production.

## Installation
```elixir
def deps do
  [
    {:membrane_hls_plugin, github: "kim-company/membrane_hls_plugin"}
  ]
end
```
## Usage
1. Initialize the source with an .m3u8 URI
2. The pipeline will receive a notification with the master playlist
3. Extract the renditions you're interested in, use them as pad identifiers when attaching a new pad.

## Gotchas
### On LFS (if tests are failing
Beware that fixtures are stored using the git LFS protocol. On debian, set it up
with
```
% sudo apt install git-lfs
# Within the repo
% git lfs install
% git lfs pull
```

If you add more fixture files, track them on LFS with `git lfs track <the
files>`.

### On other HLS plugin
[Membrane HTTP Adaptive Streaming Plugin](https://github.com/membraneframework/membrane_http_adaptive_stream_plugin) provides
a sink element for emitting HLS playlists from a pipeline. We found it
difficult to add the source functionality there because the playlist,
renditions and HLS protocol details were mixed with memebrane's sink
functionality. We would like to merge the two.

## Copyright and License
Copyright 2022, [KIM Keep In Mind GmbH](https://www.keepinmind.info/)
Licensed under the [Apache License, Version 2.0](LICENSE)
