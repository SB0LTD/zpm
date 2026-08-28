// @zpm/pdf-render — Native PDF Page Renderer
// Parses PDF files and rasterizes pages to pixel buffers.
// No external dependencies (replaces pdftoppm).
//
// Usage:
//   const pdf_render = @import("pdf_render");
//   const doc = pdf_render.parser.parse(file_data, file_size) orelse return;
//   var fb = Framebuffer{ ... };
//   pdf_render.raster.renderPage(&fb, content_stream, &state, 842.0);
//
// Output: RGBA pixel buffer, convertible to PNG via @zpm/png encoder.

pub const parser = @import("parser.sig");
pub const raster = @import("raster.sig");

pub const PdfDoc = parser.PdfDoc;
pub const Framebuffer = raster.Framebuffer;
pub const RenderState = raster.RenderState;
pub const RGBA = raster.RGBA;
