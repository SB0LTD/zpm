// @zpm/youtube/sabr — Pure-Sig SABR (Server-ABR) streaming client
//
// YouTube serves WEB-client media via SABR: a POST to serverAbrStreamingUrl
// whose body is a VideoPlaybackAbrRequest protobuf and whose response is a UMP
// stream of parts (MEDIA_HEADER / MEDIA / MEDIA_END / control signals). This
// package implements that transport in 100% allocator-free Sig:
//
//   protobuf      — the general wire codec (re-exported from @zpm/core)
//   ump           — UMP container parser + SABR part decoders
//   request       — VideoPlaybackAbrRequest builder
//   player_fields — serverAbrStreamingUrl + ustreamerConfig extraction
//   stream        — the POST -> parse -> append -> redirect loop
//
// It composes with the existing youtube stack (net.sig POST + session jar,
// manifest.sig format selection, botguard minter PO token) rather than
// reinventing HTTP/TLS/minter.

pub const protobuf = @import("protobuf");
pub const ump = @import("ump.sig");
pub const request = @import("request.sig");
pub const player_fields = @import("player_fields.sig");
pub const stream = @import("stream.sig");
