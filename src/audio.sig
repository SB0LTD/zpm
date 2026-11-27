//! Public native audio module; storage, I/O and output ownership stay external.
const api = @import("audio/root.sig");
pub const mp4 = api.mp4;
pub const wav = api.wav;
pub const aac = api.aac;
pub const resample = api.resample;
