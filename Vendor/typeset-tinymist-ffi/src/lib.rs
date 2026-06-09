// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use libc::c_char;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ffi::{CStr, CString};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};
use typst::diag::{FileError, FileResult, Severity, SourceDiagnostic};
use typst::foundations::{Bytes, Datetime, Duration, Smart};
use typst::layout::{Abs, Frame, FrameItem, Point, Size, Transform};
use typst::syntax::{
    DiagSpan, DiagSpanKind, FileId, RootedPath, Source, Span, VirtualPath, VirtualRoot,
};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Feature, Library, LibraryExt, World, WorldExt};
use typst_ide::{Completion as IdeCompletion, CompletionKind as IdeCompletionKind, IdeWorld, autocomplete};
use typst_kit::datetime::Time;
use typst_kit::downloader::SystemDownloader;
use typst_kit::files::{FileLoader, FileStore, FsRoot};
use typst_kit::fonts::{self, FontStore};
use typst_kit::packages::{FsPackages, SystemPackages, UniversePackages};
use typst_html::HtmlDocument;
use typst_layout::PagedDocument;
use typst_pdf::{PdfOptions, PdfStandards};
use typst_syntax::{SyntaxKind, SyntaxNode, parse};

pub struct TypesetTinymistSession {
    root: String,
    compile_target: String,
    package_path: String,
    package_cache_path: String,
    files: HashMap<String, String>,
}

static LSP_DEBUG_ENABLED: AtomicBool = AtomicBool::new(false);

#[derive(Serialize)]
struct StatusResponse {
    ok: bool,
    message: Option<String>,
}

#[derive(Serialize)]
struct DiagnosticResponse {
    diagnostics: Vec<Diagnostic>,
}

#[derive(Serialize)]
struct Diagnostic {
    file: String,
    start_utf8: usize,
    end_utf8: usize,
    line: usize,
    column: usize,
    severity: String,
    message: String,
}

#[derive(Serialize)]
struct CompletionResponse {
    completions: Vec<Completion>,
}

#[derive(Serialize)]
struct Completion {
    label: String,
    detail: String,
    insert_text: String,
    insert_text_format: String,
    replace_start_utf8: usize,
    replace_end_utf8: usize,
    filter_text: String,
    sort_text: String,
    documentation: String,
    kind: String,
}

#[derive(Serialize)]
struct HoverResponse {
    hover: Option<Hover>,
}

#[derive(Serialize)]
struct Hover {
    start_utf8: usize,
    end_utf8: usize,
    text: String,
}

#[derive(Serialize)]
struct SignatureHelpResponse {
    signature_help: Option<SignatureHelp>,
}

#[derive(Serialize)]
struct SignatureHelp {
    signatures: Vec<SignatureInformation>,
    active_signature: usize,
    active_parameter: usize,
}

#[derive(Serialize)]
struct SignatureInformation {
    label: String,
    documentation: String,
    parameters: Vec<ParameterInformation>,
}

#[derive(Serialize)]
struct ParameterInformation {
    label: String,
    documentation: String,
}

#[derive(Serialize)]
struct ProseRangeResponse {
    ranges: Vec<ProseRange>,
}

#[derive(Serialize)]
struct ProseRange {
    start_utf8: usize,
    end_utf8: usize,
}

#[derive(Serialize)]
struct DocumentSymbolsResponse {
    outline: Vec<OutlineItem>,
    figures: Vec<FigureItem>,
    references: Vec<ReferenceGroup>,
}

#[derive(Serialize)]
struct OutlineItem {
    title: String,
    level: usize,
    start_utf8: usize,
    end_utf8: usize,
}

#[derive(Serialize)]
struct FigureItem {
    title: String,
    kind: String,
    label: String,
    start_utf8: usize,
    end_utf8: usize,
}

#[derive(Serialize)]
struct ReferenceGroup {
    name: String,
    has_source: bool,
    source_start_utf8: usize,
    source_end_utf8: usize,
    uses: Vec<SymbolRange>,
}

#[derive(Serialize)]
struct SymbolRange {
    start_utf8: usize,
    end_utf8: usize,
}

#[derive(Serialize)]
struct RenderResponse {
    ok: bool,
    message: Option<String>,
    pages: Vec<String>,
    pdf_base64: Option<String>,
    html: Option<String>,
    diagnostics: Vec<Diagnostic>,
    source_rects: Vec<SourceRect>,
}

#[derive(Serialize)]
struct SourceRect {
    page: usize,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    file: String,
    start_utf8: usize,
    end_utf8: usize,
}

fn lsp_debug(message: impl AsRef<str>) {
    if !LSP_DEBUG_ENABLED.load(Ordering::Relaxed) {
        return;
    }
    eprintln!("[Typeset LSP Rust] {}", message.as_ref());
}

fn completion_labels(completions: &[Completion]) -> String {
    completions
        .iter()
        .take(8)
        .map(|completion| completion.label.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_session_create() -> *mut TypesetTinymistSession {
    Box::into_raw(Box::new(TypesetTinymistSession {
        root: String::new(),
        compile_target: String::new(),
        package_path: String::new(),
        package_cache_path: String::new(),
        files: HashMap::new(),
    }))
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_session_destroy(session: *mut TypesetTinymistSession) {
    if !session.is_null() {
        unsafe {
            drop(Box::from_raw(session));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_set_debug_logging(
    _session: *mut TypesetTinymistSession,
    enabled: u8,
) -> *mut c_char {
    LSP_DEBUG_ENABLED.store(enabled != 0, Ordering::Relaxed);
    into_c_string(status_ok())
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_set_workspace(
    session: *mut TypesetTinymistSession,
    root: *const c_char,
    compile_target: *const c_char,
) -> *mut c_char {
    with_session(session, |session| {
        session.root = read_c_string(root)?;
        session.compile_target = read_c_string(compile_target)?;
        lsp_debug(format!(
            "set_workspace root='{}' target='{}'",
            session.root, session.compile_target
        ));
        Ok(status_ok())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_set_package_storage(
    session: *mut TypesetTinymistSession,
    package_path: *const c_char,
    package_cache_path: *const c_char,
) -> *mut c_char {
    with_session(session, |session| {
        session.package_path = read_c_string(package_path)?;
        session.package_cache_path = read_c_string(package_cache_path)?;
        lsp_debug(format!(
            "set_package_storage local='{}' exists={} cache='{}' exists={}",
            session.package_path,
            Path::new(&session.package_path).is_dir(),
            session.package_cache_path,
            Path::new(&session.package_cache_path).is_dir()
        ));
        Ok(status_ok())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_update_file(
    session: *mut TypesetTinymistSession,
    path: *const c_char,
    text: *const c_char,
) -> *mut c_char {
    with_session(session, |session| {
        session.files.insert(read_c_string(path)?, read_c_string(text)?);
        Ok(status_ok())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_close_file(
    session: *mut TypesetTinymistSession,
    path: *const c_char,
) -> *mut c_char {
    with_session(session, |session| {
        session.files.remove(&read_c_string(path)?);
        Ok(status_ok())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_diagnostics(session: *mut TypesetTinymistSession) -> *mut c_char {
    with_session(session, |session| {
        let mut diagnostics = Vec::new();
        for (path, text) in &session.files {
            diagnostics.extend(syntax_diagnostics(path, text));
        }
        Ok(to_json(&DiagnosticResponse { diagnostics }))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_completions(
    session: *mut TypesetTinymistSession,
    path: *const c_char,
    utf8_offset: u32,
) -> *mut c_char {
    with_session(session, |session| {
        let path = read_c_string(path)?;
        let text = session.files.get(&path).cloned().unwrap_or_default();
        let workspace_paths = workspace_file_paths(&session.root)
            .into_iter()
            .filter(|workspace_path| workspace_path != &path)
            .collect::<Vec<_>>();
        lsp_debug(format!(
            "completion request path='{path}' utf8={} text_bytes={} workspace_paths={}",
            utf8_offset,
            text.len(),
            workspace_paths.len()
        ));
        let completions = completions_for(
            &text,
            utf8_offset as usize,
            &workspace_paths,
            &session.package_path,
            &session.package_cache_path,
            &session.files,
            &path,
        );
        lsp_debug(format!(
            "completion response path='{path}' count={} labels=[{}]",
            completions.len(),
            completion_labels(&completions)
        ));
        Ok(to_json(&CompletionResponse { completions }))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_hover(
    session: *mut TypesetTinymistSession,
    path: *const c_char,
    utf8_offset: u32,
) -> *mut c_char {
    with_session(session, |session| {
        let path = read_c_string(path)?;
        let text = session.files.get(&path).cloned().unwrap_or_default();
        Ok(to_json(&HoverResponse {
            hover: hover_for(&text, utf8_offset as usize),
        }))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_signature_help(
    session: *mut TypesetTinymistSession,
    path: *const c_char,
    utf8_offset: u32,
) -> *mut c_char {
    with_session(session, |session| {
        let path = read_c_string(path)?;
        let text = session.files.get(&path).cloned().unwrap_or_default();
        lsp_debug(format!(
            "signature request path='{path}' utf8={} text_bytes={}",
            utf8_offset,
            text.len()
        ));
        let signature_help = signature_help_for(
            &text,
            utf8_offset as usize,
            &session.package_path,
            &session.package_cache_path,
        );
        lsp_debug(format!(
            "signature response path='{path}' label={}",
            signature_help
                .as_ref()
                .and_then(|help| help.signatures.first())
                .map(|signature| signature.label.as_str())
                .unwrap_or("none")
        ));
        Ok(to_json(&SignatureHelpResponse { signature_help }))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_prose_ranges(
    session: *mut TypesetTinymistSession,
    path: *const c_char,
) -> *mut c_char {
    typeset_tinymist_prose_ranges_with_options(session, path, 1)
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_prose_ranges_with_options(
    session: *mut TypesetTinymistSession,
    path: *const c_char,
    ignore_commands: u8,
) -> *mut c_char {
    with_session(session, |session| {
        let path = read_c_string(path)?;
        let text = session.files.get(&path).cloned().unwrap_or_default();
        Ok(to_json(&ProseRangeResponse {
            ranges: prose_ranges_for(&text, ignore_commands != 0),
        }))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_document_symbols(
    session: *mut TypesetTinymistSession,
    path: *const c_char,
) -> *mut c_char {
    with_session(session, |session| {
        let path = read_c_string(path)?;
        let text = session.files.get(&path).cloned().unwrap_or_default();
        Ok(to_json(&document_symbols_for(&text)))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_typst_compile_svg(
    root: *const c_char,
    main_path: *const c_char,
    package_path: *const c_char,
    package_cache_path: *const c_char,
) -> *mut c_char {
    into_c_string(match compile_svg_response(root, main_path, package_path, package_cache_path) {
        Ok(response) => to_json(&response),
        Err(message) => to_json(&RenderResponse::error(message)),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_typst_compile_pdf(
    root: *const c_char,
    main_path: *const c_char,
    package_path: *const c_char,
    package_cache_path: *const c_char,
) -> *mut c_char {
    into_c_string(match compile_pdf_response(root, main_path, package_path, package_cache_path) {
        Ok(response) => to_json(&response),
        Err(message) => to_json(&RenderResponse::error(message)),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_typst_compile_html(
    root: *const c_char,
    main_path: *const c_char,
    package_path: *const c_char,
    package_cache_path: *const c_char,
) -> *mut c_char {
    into_c_string(match compile_html_response(root, main_path, package_path, package_cache_path) {
        Ok(response) => to_json(&response),
        Err(message) => to_json(&RenderResponse::error(message)),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn typeset_tinymist_string_free(string: *mut c_char) {
    if !string.is_null() {
        unsafe {
            drop(CString::from_raw(string));
        }
    }
}

fn with_session<F>(session: *mut TypesetTinymistSession, body: F) -> *mut c_char
where
    F: FnOnce(&mut TypesetTinymistSession) -> Result<String, String>,
{
    let response = if session.is_null() {
        Err("Tinymist session is null.".to_string())
    } else {
        body(unsafe { &mut *session })
    };

    match response {
        Ok(json) => into_c_string(json),
        Err(message) => into_c_string(to_json(&StatusResponse {
            ok: false,
            message: Some(message),
        })),
    }
}

fn read_c_string(value: *const c_char) -> Result<String, String> {
    if value.is_null() {
        return Err("String argument is null.".to_string());
    }

    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map(|value| value.to_string())
        .map_err(|error| error.to_string())
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value).unwrap_or_default().into_raw()
}

fn status_ok() -> String {
    to_json(&StatusResponse {
        ok: true,
        message: None,
    })
}

fn to_json<T: Serialize>(value: &T) -> String {
    serde_json::to_string(value).unwrap_or_else(|error| {
        format!(
            "{{\"ok\":false,\"message\":\"{}\"}}",
            error.to_string().replace('"', "\\\"")
        )
    })
}

impl RenderResponse {
    fn error(message: String) -> Self {
        Self {
            ok: false,
            message: Some(message),
            pages: Vec::new(),
            pdf_base64: None,
            html: None,
            diagnostics: Vec::new(),
            source_rects: Vec::new(),
        }
    }

    fn compile_error(message: String, diagnostics: Vec<Diagnostic>) -> Self {
        Self {
            ok: false,
            message: Some(message),
            pages: Vec::new(),
            pdf_base64: None,
            html: None,
            diagnostics,
            source_rects: Vec::new(),
        }
    }
}

fn compile_svg_response(
    root: *const c_char,
    main_path: *const c_char,
    package_path: *const c_char,
    package_cache_path: *const c_char,
) -> Result<RenderResponse, String> {
    let root = read_c_string(root)?;
    let main_path = read_c_string(main_path)?;
    let package_path = read_c_string(package_path)?;
    let package_cache_path = read_c_string(package_cache_path)?;
    let (world, document, warnings) =
        match compile_paged_document(&root, &main_path, &package_path, &package_cache_path) {
            Ok(compilation) => compilation,
            Err(response) => return Ok(response),
        };
    let diagnostics = render_diagnostics(&world, warnings.iter());
    let svg_options = typst_svg::SvgOptions::default();
    let pages = document
        .pages()
        .iter()
        .map(|page| typst_svg::svg(page, &svg_options))
        .collect::<Vec<_>>();
    let source_rects = render_source_rects(&world, &document);
    Ok(RenderResponse {
        ok: true,
        message: None,
        pages,
        pdf_base64: None,
        html: None,
        diagnostics,
        source_rects,
    })
}

fn compile_pdf_response(
    root: *const c_char,
    main_path: *const c_char,
    package_path: *const c_char,
    package_cache_path: *const c_char,
) -> Result<RenderResponse, String> {
    let root = read_c_string(root)?;
    let main_path = read_c_string(main_path)?;
    let package_path = read_c_string(package_path)?;
    let package_cache_path = read_c_string(package_cache_path)?;
    let (world, document, warnings) =
        match compile_paged_document(&root, &main_path, &package_path, &package_cache_path) {
            Ok(compilation) => compilation,
            Err(response) => return Ok(response),
        };
    let diagnostics = render_diagnostics(&world, warnings.iter());
    let pdf = match typst_pdf::pdf(
        &document,
        &PdfOptions {
            ident: Smart::Auto,
            timestamp: None,
            page_ranges: None,
            standards: PdfStandards::default(),
            tagged: false,
        },
    ) {
        Ok(pdf) => pdf,
        Err(errors) => return Ok(RenderResponse::error(render_error_message(&world, &errors))),
    };

    Ok(RenderResponse {
        ok: true,
        message: None,
        pages: Vec::new(),
        pdf_base64: Some(BASE64.encode(pdf)),
        html: None,
        diagnostics,
        source_rects: render_source_rects(&world, &document),
    })
}

fn compile_html_response(
    root: *const c_char,
    main_path: *const c_char,
    package_path: *const c_char,
    package_cache_path: *const c_char,
) -> Result<RenderResponse, String> {
    let root = read_c_string(root)?;
    let main_path = read_c_string(main_path)?;
    let package_path = read_c_string(package_path)?;
    let package_cache_path = read_c_string(package_cache_path)?;
    let world = RenderWorld::new_for_html(&root, &main_path, &package_path, &package_cache_path)?;
    let typst::diag::Warned { output, warnings } = typst::compile::<HtmlDocument>(&world);
    let document = match output {
        Ok(document) => document,
        Err(errors) => {
            let diagnostics = render_diagnostics(&world, errors.iter().chain(warnings.iter()));
            let message = if diagnostics.is_empty() {
                "Typst HTML compilation failed.".to_string()
            } else {
                diagnostics_to_conventional_message(&diagnostics)
            };
            return Ok(RenderResponse::compile_error(message, diagnostics));
        }
    };
    let diagnostics = render_diagnostics(&world, warnings.iter());
    let html = match typst_html::html(&document) {
        Ok(html) => html,
        Err(errors) => return Ok(RenderResponse::error(render_error_message(&world, &errors))),
    };

    Ok(RenderResponse {
        ok: true,
        message: None,
        pages: Vec::new(),
        pdf_base64: None,
        html: Some(html),
        diagnostics,
        source_rects: Vec::new(),
    })
}

fn compile_paged_document(
    root: &str,
    main_path: &str,
    package_path: &str,
    package_cache_path: &str,
) -> Result<(RenderWorld, PagedDocument, Vec<SourceDiagnostic>), RenderResponse> {
    let world = RenderWorld::new(root, main_path, package_path, package_cache_path)
        .map_err(RenderResponse::error)?;
    let typst::diag::Warned { output, warnings } = typst::compile::<PagedDocument>(&world);
    match output {
        Ok(document) => Ok((world, document, warnings.into_iter().collect())),
        Err(errors) => {
            let diagnostics = render_diagnostics(&world, errors.iter().chain(warnings.iter()));
            let message = if diagnostics.is_empty() {
                "Typst compilation failed.".to_string()
            } else {
                diagnostics_to_conventional_message(&diagnostics)
            };
            Err(RenderResponse::compile_error(message, diagnostics))
        }
    }
}

fn render_error_message(world: &RenderWorld, errors: &[SourceDiagnostic]) -> String {
    let diagnostics = render_diagnostics(world, errors.iter());
    if diagnostics.is_empty() {
        "Typst export failed.".to_string()
    } else {
        diagnostics_to_conventional_message(&diagnostics)
    }
}

#[derive(Clone, Copy)]
struct SourceRectState {
    transform: Transform,
}

impl SourceRectState {
    fn new() -> Self {
        Self {
            transform: Transform::identity(),
        }
    }

    fn pre_translate(self, pos: Point) -> Self {
        self.pre_concat(Transform::translate(pos.x, pos.y))
    }

    fn pre_concat(self, transform: Transform) -> Self {
        Self {
            transform: self.transform.pre_concat(transform),
        }
    }
}

fn render_source_rects(world: &RenderWorld, document: &PagedDocument) -> Vec<SourceRect> {
    let mut rects = Vec::new();
    for (page_index, page) in document.pages().iter().enumerate() {
        collect_source_rects_in_frame(
            world,
            page_index,
            &page.frame,
            SourceRectState::new(),
            &mut rects,
        );
    }
    rects
}

fn collect_source_rects_in_frame(
    world: &RenderWorld,
    page: usize,
    frame: &Frame,
    state: SourceRectState,
    rects: &mut Vec<SourceRect>,
) {
    for (pos, item) in frame.items() {
        let state = state.pre_translate(*pos);
        match item {
            FrameItem::Group(group) => {
                collect_source_rects_in_frame(
                    world,
                    page,
                    &group.frame,
                    state.pre_concat(group.transform),
                    rects,
                );
            }
            FrameItem::Text(text) => {
                let mut x = Abs::zero();
                let mut y = Abs::zero();
                for glyph in &text.glyphs {
                    let width = glyph.x_advance.at(text.size);
                    let height = text.size;
                    if let Some((file, start_utf8, end_utf8)) = source_range_for_glyph(
                        world,
                        glyph.span.0,
                        glyph.span.1,
                        glyph.range().len(),
                    )
                    {
                        push_source_rect(
                            rects,
                            SourceRectGeometry {
                                page,
                                transform: state.transform,
                                origin: Point::new(x, y - height),
                                size: Size::new(width, height),
                            },
                            file,
                            start_utf8,
                            end_utf8,
                        );
                    }
                    x += width;
                    y += glyph.y_advance.at(text.size);
                }
            }
            FrameItem::Shape(shape, span) => {
                if let Some((file, start_utf8, end_utf8)) = source_range_for_span(world, *span) {
                    let bounds = shape.bbox(true);
                    push_source_rect(
                        rects,
                        SourceRectGeometry {
                            page,
                            transform: state.transform,
                            origin: bounds.min,
                            size: bounds.size(),
                        },
                        file,
                        start_utf8,
                        end_utf8,
                    );
                }
            }
            FrameItem::Image(_, size, span) => {
                if let Some((file, start_utf8, end_utf8)) = source_range_for_span(world, *span) {
                    push_source_rect(
                        rects,
                        SourceRectGeometry {
                            page,
                            transform: state.transform,
                            origin: Point::zero(),
                            size: *size,
                        },
                        file,
                        start_utf8,
                        end_utf8,
                    );
                }
            }
            FrameItem::Link(_, _) | FrameItem::Tag(_) => {}
        }
    }
}

struct SourceRectGeometry {
    page: usize,
    transform: Transform,
    origin: Point,
    size: Size,
}

fn push_source_rect(
    rects: &mut Vec<SourceRect>,
    geometry: SourceRectGeometry,
    file: String,
    start_utf8: usize,
    end_utf8: usize,
) {
    let Some((x, y, width, height)) =
        transformed_bounding_rect(geometry.transform, geometry.origin, geometry.size)
    else {
        return;
    };

    if width <= 0.05 || height <= 0.05 {
        return;
    }

    rects.push(SourceRect {
        page: geometry.page,
        x,
        y,
        width,
        height,
        file,
        start_utf8,
        end_utf8,
    });
}

fn transformed_bounding_rect(
    transform: Transform,
    origin: Point,
    size: Size,
) -> Option<(f64, f64, f64, f64)> {
    let corners = [
        origin,
        Point::new(origin.x + size.x, origin.y),
        Point::new(origin.x, origin.y + size.y),
        Point::new(origin.x + size.x, origin.y + size.y),
    ]
    .map(|point| point.transform(transform));

    let min_x = corners
        .iter()
        .map(|point| point.x.to_pt())
        .fold(f64::INFINITY, f64::min);
    let max_x = corners
        .iter()
        .map(|point| point.x.to_pt())
        .fold(f64::NEG_INFINITY, f64::max);
    let min_y = corners
        .iter()
        .map(|point| point.y.to_pt())
        .fold(f64::INFINITY, f64::min);
    let max_y = corners
        .iter()
        .map(|point| point.y.to_pt())
        .fold(f64::NEG_INFINITY, f64::max);

    if !min_x.is_finite() || !max_x.is_finite() || !min_y.is_finite() || !max_y.is_finite() {
        return None;
    }

    Some((min_x, min_y, max_x - min_x, max_y - min_y))
}

fn source_range_for_glyph(
    world: &RenderWorld,
    span: Span,
    span_offset: u16,
    glyph_len: usize,
) -> Option<(String, usize, usize)> {
    let id = span.id()?;
    let source = world.source(id).ok()?;
    let file = world.name(id);

    if let Some(node) = source.find(span) {
        if matches!(node.kind(), SyntaxKind::Text | SyntaxKind::MathText) {
            let range = node.range();
            let start = (range.start + usize::from(span_offset)).min(range.end);
            let end = (start + glyph_len).min(range.end).max(start);
            return Some((file, start, end));
        }

        let offset = node.offset();
        return Some((file, offset, offset));
    }

    let range = world.range(span)?;
    Some((file, range.start, range.end.max(range.start)))
}

fn source_range_for_span(world: &RenderWorld, span: Span) -> Option<(String, usize, usize)> {
    let id = span.id()?;
    let file = world.name(id);
    let range = world.range(span)?;
    Some((file, range.start, range.end.max(range.start)))
}

fn render_diagnostics<'a>(
    world: &RenderWorld,
    diagnostics: impl IntoIterator<Item = &'a SourceDiagnostic>,
) -> Vec<Diagnostic> {
    diagnostics
        .into_iter()
        .map(|diagnostic| render_diagnostic(world, diagnostic))
        .collect()
}

fn render_diagnostic(world: &RenderWorld, diagnostic: &SourceDiagnostic) -> Diagnostic {
    let id = diagnostic.span.id();
    let file = id
        .map(|id| world.name(id))
        .unwrap_or_else(|| world.main_path.clone());
    let source = id.and_then(|id| world.source(id).ok());
    let range = world.range(diagnostic.span).unwrap_or(0..0);
    let (line, column) = source
        .as_ref()
        .and_then(|source| source.lines().byte_to_line_column(range.start))
        .map(|(line, column)| (line + 1, column + 1))
        .unwrap_or((1, 1));
    Diagnostic {
        file,
        start_utf8: range.start,
        end_utf8: range.end.max(range.start + 1),
        line,
        column,
        severity: match diagnostic.severity {
            Severity::Error => "error",
            Severity::Warning => "warning",
        }
        .to_string(),
        message: diagnostic.message.to_string(),
    }
}

fn diagnostics_to_conventional_message(diagnostics: &[Diagnostic]) -> String {
    diagnostics
        .iter()
        .map(|diagnostic| {
            format!(
                "{}:{}:{}: {}: {}",
                diagnostic.file,
                diagnostic.line,
                diagnostic.column,
                diagnostic.severity,
                diagnostic.message
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

struct RenderWorld {
    main_path: String,
    library: LazyHash<Library>,
    fonts: FontStore,
    files: FileStore<RenderFiles>,
    now: Time,
}

impl RenderWorld {
    fn new(
        root: &str,
        main_path: &str,
        package_path: &str,
        package_cache_path: &str,
    ) -> Result<Self, String> {
        Self::new_with_html_feature(root, main_path, package_path, package_cache_path, false)
    }

    fn new_for_html(
        root: &str,
        main_path: &str,
        package_path: &str,
        package_cache_path: &str,
    ) -> Result<Self, String> {
        Self::new_with_html_feature(root, main_path, package_path, package_cache_path, true)
    }

    fn new_with_html_feature(
        root: &str,
        main_path: &str,
        package_path: &str,
        package_cache_path: &str,
        html_enabled: bool,
    ) -> Result<Self, String> {
        let files = RenderFiles::new(root, main_path, package_path, package_cache_path)?;
        let library = if html_enabled {
            Library::builder()
                .with_features([Feature::Html].into_iter().collect())
                .build()
        } else {
            Library::builder().build()
        };
        Ok(Self {
            main_path: main_path.to_string(),
            library: LazyHash::new(library),
            fonts: discover_fonts(),
            files: FileStore::new(files),
            now: Time::system(),
        })
    }

    fn name(&self, id: FileId) -> String {
        let vpath = id.vpath();
        match id.root() {
            VirtualRoot::Project => vpath.get_without_slash().into(),
            VirtualRoot::Package(package) => format!("{package}{}", vpath.get_with_slash()),
        }
    }
}

impl World for RenderWorld {
    fn library(&self) -> &LazyHash<Library> {
        &self.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        self.fonts.book()
    }

    fn main(&self) -> FileId {
        self.files.loader().main
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        self.files.source(id)
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        self.files.file(id)
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.fonts.font(index)
    }

    fn today(&self, offset: Option<Duration>) -> Option<Datetime> {
        self.now.today(offset)
    }
}

struct RenderFiles {
    main: FileId,
    project: FsRoot,
    packages: SystemPackages,
}

impl RenderFiles {
    fn new(
        root: &str,
        main_path: &str,
        package_path: &str,
        package_cache_path: &str,
    ) -> Result<Self, String> {
        let root = PathBuf::from(root)
            .canonicalize()
            .map_err(|error| format!("Typst root is unavailable: {error}"))?;
        let input = root
            .join(main_path)
            .canonicalize()
            .map_err(|error| format!("Typst input file is unavailable: {error}"))?;
        let virtual_path = VirtualPath::virtualize(&root, &input)
            .map_err(|error| format!("Typst input file must be inside the package: {error:?}"))?;
        let main = RootedPath::new(VirtualRoot::Project, virtual_path).intern();
        let packages = SystemPackages::from_parts(
            Some(FsPackages::new(package_path)),
            Some(FsPackages::new(package_cache_path)),
            UniversePackages::new(SystemDownloader::new("Typeset")),
        );

        Ok(Self {
            main,
            project: FsRoot::new(root),
            packages,
        })
    }

    fn root(&self, id: FileId) -> FileResult<FsRoot> {
        Ok(match id.root() {
            VirtualRoot::Project => self.project.clone(),
            VirtualRoot::Package(spec) => self.packages.obtain(spec)?,
        })
    }
}

impl FileLoader for RenderFiles {
    fn load(&self, id: FileId) -> FileResult<Bytes> {
        self.root(id)?.load(id.vpath())
    }
}

fn discover_fonts() -> FontStore {
    let mut font_store = FontStore::new();
    font_store.extend(fonts::embedded());
    font_store.extend(fonts::system());
    font_store
}

fn syntax_diagnostics(path: &str, text: &str) -> Vec<Diagnostic> {
    let source = Source::detached(text);
    let (errors, _warnings) = source.root().errors_and_warnings();
    errors
        .into_iter()
        .map(|error| {
            let range = diag_span_range(&source, error.span).unwrap_or(0..0);
            let (line, column) = line_column_for_utf8_offset(text, range.start);
            Diagnostic {
                file: path.to_string(),
                start_utf8: range.start,
                end_utf8: range.end.max(range.start + 1),
                line,
                column,
                severity: "error".to_string(),
                message: error.message.to_string(),
            }
        })
        .collect()
}

/// Resolve a diagnostic span to a byte range within a single source (used when
/// there is no `World` available, e.g. for standalone syntax diagnostics).
fn diag_span_range(source: &Source, span: DiagSpan) -> Option<std::ops::Range<usize>> {
    match span.get() {
        DiagSpanKind::Detached => None,
        DiagSpanKind::Number { num, sub_range, .. } => source.range(num, sub_range),
        DiagSpanKind::Range { range, .. } => Some(range),
    }
}

fn line_column_for_utf8_offset(text: &str, offset: usize) -> (usize, usize) {
    let clamped = clamp_to_char_boundary(text, offset);
    let prefix = text.get(..clamped).unwrap_or("");
    let line = prefix.bytes().filter(|byte| *byte == b'\n').count() + 1;
    let line_start = prefix.rfind('\n').map(|index| index + 1).unwrap_or(0);
    let column = prefix[line_start..].chars().count() + 1;
    (line, column)
}

fn completions_for(
    text: &str,
    utf8_offset: usize,
    workspace_paths: &[String],
    package_path: &str,
    package_cache_path: &str,
    session_files: &HashMap<String, String>,
    main_path: &str,
) -> Vec<Completion> {
    let offset = clamp_to_char_boundary(text, utf8_offset);
    if let Some(path_context) = path_completion_context(text, offset) {
        let typed = text
            .get(path_context.replace_start_utf8..path_context.replace_end_utf8)
            .unwrap_or("");
        lsp_debug(format!(
            "completion branch=path kind={:?} typed='{typed}'",
            path_context.kind
        ));
        return path_completions(workspace_paths, text, path_context, package_path, package_cache_path);
    }

    let replacement = completion_replacement_range(text, offset);
    if let Some(import_context) = package_import_list_completion_context(text, offset) {
        lsp_debug(format!(
            "completion branch=package-import-list spec={} replace={}..{}",
            import_context.spec.label(),
            import_context.replace_start_utf8,
            import_context.replace_end_utf8
        ));
        return package_import_item_completions(
            import_context,
            package_path,
            package_cache_path,
        );
    }

    // Everything else is delegated to typst's real autocompletion engine
    // (`typst-ide`), which is fully context-aware: standard-library functions,
    // locally-bound `#let` variables, function parameters, field accesses
    // (`obj.field`), set/show rules, language keywords, and `@label` references
    // all originate here. Installed-package export symbols are supplemented
    // separately, because the lightweight completion world does not load
    // packages from disk.
    let mut completions = autocomplete_completions(session_files, main_path, text, offset);

    let package_completions = package_symbol_completions(
        text,
        replacement.clone(),
        package_path,
        package_cache_path,
    );
    lsp_debug(format!(
        "completion branch=autocomplete items={} package_symbols={}",
        completions.len(),
        package_completions.len()
    ));
    completions.extend(package_completions);
    completions
}

/// A minimal [`World`] / [`IdeWorld`] used solely to drive `typst-ide`'s
/// autocompletion. It serves the session's in-memory editor buffers as sources
/// (so completions reflect unsaved edits and cross-file `#let` bindings), the
/// full standard library, and an empty font book. It deliberately avoids the
/// filesystem and any font scanning, so it is cheap to build on every keystroke.
struct CompletionWorld {
    main: FileId,
    sources: HashMap<FileId, Source>,
    now: Time,
}

impl World for CompletionWorld {
    fn library(&self) -> &LazyHash<Library> {
        shared_completion_library()
    }

    fn book(&self) -> &LazyHash<FontBook> {
        shared_empty_font_book()
    }

    fn main(&self) -> FileId {
        self.main
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        self.sources
            .get(&id)
            .cloned()
            .ok_or_else(|| FileError::NotFound(PathBuf::from(id.vpath().get_with_slash())))
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        Err(FileError::NotFound(
            PathBuf::from(id.vpath().get_with_slash()),
        ))
    }

    fn font(&self, _index: usize) -> Option<Font> {
        None
    }

    fn today(&self, offset: Option<Duration>) -> Option<Datetime> {
        self.now.today(offset)
    }
}

impl IdeWorld for CompletionWorld {
    fn upcast(&self) -> &dyn World {
        self
    }

    fn files(&self) -> Vec<FileId> {
        self.sources.keys().copied().collect()
    }
}

/// The standard library, built once and shared. `World: Send + Sync` guarantees
/// `LazyHash<Library>` is `Sync`, so a single instance can back every completion
/// request rather than rebuilding the library on each keystroke.
fn shared_completion_library() -> &'static LazyHash<Library> {
    static LIBRARY: OnceLock<LazyHash<Library>> = OnceLock::new();
    LIBRARY.get_or_init(|| LazyHash::new(Library::builder().build()))
}

/// An empty font book, shared. Font-family completion is unavailable (an
/// acceptable trade-off), but in exchange we never pay for a system font scan.
fn shared_empty_font_book() -> &'static LazyHash<FontBook> {
    static BOOK: OnceLock<LazyHash<FontBook>> = OnceLock::new();
    BOOK.get_or_init(|| LazyHash::new(FontBook::new()))
}

/// Builds the [`FileId`] for a project-relative path (the form stored in the
/// session's file map).
fn project_file_id(path: &str) -> Option<FileId> {
    let vpath = VirtualPath::new(path).ok()?;
    Some(RootedPath::new(VirtualRoot::Project, vpath).intern())
}

/// Assembles a [`CompletionWorld`] from the session's in-memory files, ensuring
/// the file being edited reflects the exact current buffer (`main_text`).
fn build_completion_world(
    session_files: &HashMap<String, String>,
    main_path: &str,
    main_text: &str,
) -> Option<CompletionWorld> {
    let main = project_file_id(main_path)?;
    let mut sources = HashMap::new();
    for (path, content) in session_files {
        if let Some(id) = project_file_id(path) {
            sources.insert(id, Source::new(id, content.clone()));
        }
    }
    sources.insert(main, Source::new(main, main_text.to_string()));
    Some(CompletionWorld {
        main,
        sources,
        now: Time::system(),
    })
}

/// Runs `typst-ide` autocompletion at `offset` and converts the results into the
/// FFI completion shape the editor consumes.
fn autocomplete_completions(
    session_files: &HashMap<String, String>,
    main_path: &str,
    text: &str,
    offset: usize,
) -> Vec<Completion> {
    let Some(world) = build_completion_world(session_files, main_path, text) else {
        return Vec::new();
    };
    let Ok(source) = world.source(world.main()) else {
        return Vec::new();
    };

    // `explicit = false`: only complete where the user is genuinely in the
    // middle of an identifier, field access, reference, etc. This keeps plain
    // prose clean — typing a word mid-sentence yields no completions.
    let Some((from, items)) = autocomplete(&world, None::<&PagedDocument>, &source, offset, false)
    else {
        return Vec::new();
    };

    items
        .into_iter()
        .map(|item| convert_ide_completion(item, from, offset))
        .collect()
}

/// Converts a `typst-ide` completion into the FFI [`Completion`].
fn convert_ide_completion(item: IdeCompletion, from: usize, cursor: usize) -> Completion {
    let label = item.label.to_string();
    let apply = item
        .apply
        .map(|apply| apply.to_string())
        .unwrap_or_else(|| label.clone());
    let kind = match item.kind {
        IdeCompletionKind::Syntax => "keyword",
        IdeCompletionKind::Func => "function",
        IdeCompletionKind::Type => "type",
        IdeCompletionKind::Param => "field",
        IdeCompletionKind::Constant => "constant",
        IdeCompletionKind::Path => "file",
        IdeCompletionKind::Package => "module",
        IdeCompletionKind::Label => "reference",
        IdeCompletionKind::Font => "text",
        IdeCompletionKind::Symbol(_) => "constant",
    };

    Completion {
        label: label.clone(),
        detail: item
            .detail
            .map(|detail| detail.to_string())
            .unwrap_or_else(|| "Typst".to_string()),
        insert_text: lsp_snippet_from_typst(&apply),
        insert_text_format: "snippet".to_string(),
        replace_start_utf8: from,
        replace_end_utf8: cursor,
        filter_text: label.clone(),
        sort_text: label,
        documentation: String::new(),
        kind: kind.to_string(),
    }
}

/// Rewrites typst's snippet placeholders (`${}`, `${name}`, `${1 < 2}`) into the
/// numbered LSP form (`${1:}`, `${1:name}`, `${1:1 < 2}`) understood by the
/// editor's snippet resolver, so the first placeholder becomes the cursor. A
/// placeholder already in numbered form (`${2:x}`) is passed through untouched.
/// Literal text (including the `{`/`}` of code blocks) is preserved verbatim.
fn lsp_snippet_from_typst(apply: &str) -> String {
    let mut out = String::new();
    let mut counter = 1u32;
    let mut rest = apply;
    while let Some(pos) = rest.find("${") {
        out.push_str(&rest[..pos]);
        let after = &rest[pos + 2..];
        let Some(close) = after.find('}') else {
            out.push_str("${");
            rest = after;
            continue;
        };
        let inner = &after[..close];
        let digits = inner.bytes().take_while(u8::is_ascii_digit).count();
        let already_numbered =
            digits > 0 && (digits == inner.len() || inner.as_bytes()[digits] == b':');
        if already_numbered {
            out.push_str("${");
            out.push_str(inner);
            out.push('}');
        } else {
            out.push_str(&format!("${{{counter}:{inner}}}"));
            counter += 1;
        }
        rest = &after[close + 1..];
    }
    out.push_str(rest);
    out
}

struct PathCompletionContext {
    replace_start_utf8: usize,
    replace_end_utf8: usize,
    kind: PathCompletionKind,
}

#[derive(Clone, Copy, Debug)]
enum PathCompletionKind {
    Image,
    TypstSource,
}

fn path_completion_context(text: &str, utf8_offset: usize) -> Option<PathCompletionContext> {
    let prefix = text.get(..utf8_offset)?;
    let line_start = prefix.rfind('\n').map(|index| index + 1).unwrap_or(0);
    let line_prefix = &prefix[line_start..];
    if unescaped_quote_count(line_prefix) % 2 == 0 {
        return None;
    }
    let quote_in_line = line_prefix.rfind('"')?;
    let quote_start = line_start + quote_in_line;
    if is_escaped_quote(prefix.as_bytes(), quote_start) {
        return None;
    }

    let before_quote = &text[line_start..quote_start];
    let kind = if before_quote.contains("#image") {
        PathCompletionKind::Image
    } else if before_quote.contains("#include") || before_quote.contains("#import") {
        PathCompletionKind::TypstSource
    } else {
        return None;
    };

    Some(PathCompletionContext {
        replace_start_utf8: quote_start + 1,
        replace_end_utf8: utf8_offset,
        kind,
    })
}

fn path_completions(
    workspace_paths: &[String],
    text: &str,
    context: PathCompletionContext,
    package_path: &str,
    package_cache_path: &str,
) -> Vec<Completion> {
    let typed = text
        .get(context.replace_start_utf8..context.replace_end_utf8)
        .unwrap_or("");

    if matches!(context.kind, PathCompletionKind::TypstSource) && typed.starts_with('@') {
        let packages = installed_package_completions(package_path, package_cache_path, &context);
        if !packages.is_empty() {
            lsp_debug(format!(
                "path completions returning package specs count={} labels=[{}]",
                packages.len(),
                completion_labels(&packages)
            ));
            return packages;
        }
        lsp_debug("path completions no installed package specs matched; falling back to workspace paths");
    }

    let completions = workspace_paths
        .iter()
        .filter(|path| path_matches_completion_kind(path, context.kind))
        .map(|path| Completion {
            label: path.clone(),
            detail: "Package File".to_string(),
            insert_text: path.clone(),
            insert_text_format: "plain_text".to_string(),
            replace_start_utf8: context.replace_start_utf8,
            replace_end_utf8: context.replace_end_utf8,
            filter_text: path.clone(),
            sort_text: path.clone(),
            documentation: "Insert a package-relative file path.".to_string(),
            kind: "file".to_string(),
        })
        .collect::<Vec<_>>();
    lsp_debug(format!(
        "path completions workspace count={} labels=[{}]",
        completions.len(),
        completion_labels(&completions)
    ));
    completions
}

fn path_matches_completion_kind(path: &str, kind: PathCompletionKind) -> bool {
    let lower = path.to_ascii_lowercase();
    match kind {
        PathCompletionKind::Image => {
            matches!(
                lower.rsplit('.').next(),
                Some("png" | "jpg" | "jpeg" | "gif" | "svg" | "webp" | "bmp" | "tif" | "tiff")
            )
        }
        PathCompletionKind::TypstSource => lower.ends_with(".typ"),
    }
}

fn unescaped_quote_count(text: &str) -> usize {
    let mut count = 0;
    let mut escaped = false;
    for character in text.chars() {
        if escaped {
            escaped = false;
            continue;
        }
        if character == '\\' {
            escaped = true;
            continue;
        }
        if character == '"' {
            count += 1;
        }
    }
    count
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct PackageSpecParts {
    namespace: String,
    name: String,
    version: String,
}

impl PackageSpecParts {
    fn label(&self) -> String {
        format!("@{}/{}:{}", self.namespace, self.name, self.version)
    }
}

#[derive(Clone, Debug)]
struct PackageImport {
    spec: PackageSpecParts,
    module_name: Option<String>,
    wildcard: bool,
    items: Vec<String>,
}

struct PackageImportListCompletionContext {
    spec: PackageSpecParts,
    replace_start_utf8: usize,
    replace_end_utf8: usize,
}

#[derive(Clone, Debug)]
struct PackageExport {
    name: String,
    kind: String,
    documentation: String,
    signature: Option<PackageSignature>,
}

#[derive(Clone, Debug)]
struct PackageSignature {
    label: String,
    parameters: Vec<String>,
}

fn installed_package_completions(
    package_path: &str,
    package_cache_path: &str,
    context: &PathCompletionContext,
) -> Vec<Completion> {
    let mut specs = BTreeMap::<String, PackageSpecParts>::new();
    for root in [package_path, package_cache_path] {
        collect_installed_package_specs(Path::new(root), &mut specs);
    }
    lsp_debug(format!(
        "installed package specs local='{}' cache='{}' count={}",
        package_path,
        package_cache_path,
        specs.len()
    ));

    specs
        .into_values()
        .map(|spec| {
            let label = spec.label();
            Completion {
                label: label.clone(),
                detail: "Installed Typst Package".to_string(),
                insert_text: label.clone(),
                insert_text_format: "plain_text".to_string(),
                replace_start_utf8: context.replace_start_utf8,
                replace_end_utf8: context.replace_end_utf8,
                filter_text: label.clone(),
                sort_text: label.clone(),
                documentation: "Insert an installed Typst package spec.".to_string(),
                kind: "module".to_string(),
            }
        })
        .collect()
}

fn collect_installed_package_specs(root: &Path, specs: &mut BTreeMap<String, PackageSpecParts>) {
    let Ok(namespaces) = fs::read_dir(root) else {
        return;
    };

    for namespace in namespaces.flatten() {
        let namespace_path = namespace.path();
        if !namespace_path.is_dir() {
            continue;
        }
        let namespace_name = namespace.file_name().to_string_lossy().to_string();
        let Ok(packages) = fs::read_dir(&namespace_path) else {
            continue;
        };

        for package in packages.flatten() {
            let package_path = package.path();
            if !package_path.is_dir() {
                continue;
            }
            let package_name = package.file_name().to_string_lossy().to_string();
            let Ok(versions) = fs::read_dir(&package_path) else {
                continue;
            };

            for version in versions.flatten() {
                let version_path = version.path();
                if !version_path.is_dir() || !version_path.join("typst.toml").is_file() {
                    continue;
                }
                let spec = PackageSpecParts {
                    namespace: namespace_name.clone(),
                    name: package_name.clone(),
                    version: version.file_name().to_string_lossy().to_string(),
                };
                specs.insert(spec.label(), spec);
            }
        }
    }
}

fn package_import_list_completion_context(
    text: &str,
    utf8_offset: usize,
) -> Option<PackageImportListCompletionContext> {
    let prefix = text.get(..utf8_offset)?;
    let line_start = prefix.rfind('\n').map(|index| index + 1).unwrap_or(0);
    let line_prefix = prefix.get(line_start..)?;
    let import_start = line_prefix.find("#import")?;
    let rest_start = import_start + "#import".len();
    let rest_with_space = line_prefix.get(rest_start..)?;
    let rest = rest_with_space.trim_start();
    let rest_leading_space = rest_with_space.len() - rest.len();
    let rest_absolute_start = line_start + rest_start + rest_leading_space;
    let (import_path, suffix) = read_quoted_string(rest)?;
    let spec = parse_package_spec(import_path)?;
    let suffix_absolute_start = rest_absolute_start + rest.len() - suffix.len();
    let colon = suffix.find(':')?;
    let after_colon_start = colon + 1;
    let after_colon = suffix.get(after_colon_start..)?;
    let last_separator = after_colon.rfind(',').map(|index| index + 1).unwrap_or(0);
    let item_prefix = after_colon.get(last_separator..)?;
    let item_leading_space = item_prefix.len() - item_prefix.trim_start().len();
    let replace_start_utf8 =
        suffix_absolute_start + after_colon_start + last_separator + item_leading_space;

    Some(PackageImportListCompletionContext {
        spec,
        replace_start_utf8,
        replace_end_utf8: utf8_offset,
    })
}

fn package_import_item_completions(
    context: PackageImportListCompletionContext,
    package_path: &str,
    package_cache_path: &str,
) -> Vec<Completion> {
    let Some(package_root) = package_root_for_spec(&context.spec, package_path, package_cache_path)
    else {
        lsp_debug(format!(
            "package import-list root missing spec={} local='{}' cache='{}'",
            context.spec.label(),
            package_path,
            package_cache_path
        ));
        return Vec::new();
    };
    let exports = package_exports(&package_root);
    lsp_debug(format!(
        "package import-list exports spec={} root='{}' count={}",
        context.spec.label(),
        package_root.display(),
        exports.len()
    ));
    exports
        .into_values()
        .map(|export| Completion {
            label: export.name.clone(),
            detail: format!("{} export", context.spec.name),
            insert_text: export.name.clone(),
            insert_text_format: "plain_text".to_string(),
            replace_start_utf8: context.replace_start_utf8,
            replace_end_utf8: context.replace_end_utf8,
            filter_text: export.name.clone(),
            sort_text: export.name.clone(),
            documentation: if export.documentation.is_empty() {
                format!("Imported from {}.", context.spec.label())
            } else {
                export.documentation
            },
            kind: export.kind,
        })
        .collect()
}

fn package_symbol_completions(
    text: &str,
    replacement: std::ops::Range<usize>,
    package_path: &str,
    package_cache_path: &str,
) -> Vec<Completion> {
    let imports = package_imports_in_text(text);
    if imports.is_empty() {
        lsp_debug("package symbols no package imports found");
        return Vec::new();
    }

    let receiver = dot_receiver_before(text, replacement.start);
    lsp_debug(format!(
        "package symbols imports={} receiver={:?} replace={}..{}",
        imports.len(),
        receiver,
        replacement.start,
        replacement.end
    ));
    let mut completions = BTreeMap::<String, Completion>::new();

    for import in imports {
        let Some(package_root) =
            package_root_for_spec(&import.spec, package_path, package_cache_path)
        else {
            lsp_debug(format!(
                "package symbols root missing spec={} local='{}' cache='{}'",
                import.spec.label(),
                package_path,
                package_cache_path
            ));
            continue;
        };
        let exports = package_exports(&package_root);
        lsp_debug(format!(
            "package symbols spec={} root='{}' exports={} module={:?} wildcard={} items={:?}",
            import.spec.label(),
            package_root.display(),
            exports.len(),
            import.module_name,
            import.wildcard,
            import.items
        ));

        if let Some(receiver) = &receiver {
            if import.module_name.as_deref() != Some(receiver.as_str()) {
                continue;
            }
            for export in exports.values() {
                insert_package_export_completion(
                    &mut completions,
                    export,
                    replacement.clone(),
                    &import.spec,
                );
            }
            continue;
        }

        if let Some(module_name) = &import.module_name {
            completions.entry(module_name.clone()).or_insert_with(|| Completion {
                label: module_name.clone(),
                detail: "Typst Package".to_string(),
                insert_text: module_name.clone(),
                insert_text_format: "plain_text".to_string(),
                replace_start_utf8: replacement.start,
                replace_end_utf8: replacement.end,
                filter_text: module_name.clone(),
                sort_text: module_name.clone(),
                documentation: format!("Imported module from {}.", import.spec.label()),
                kind: "module".to_string(),
            });
        }

        if import.wildcard {
            for export in exports.values() {
                insert_package_export_completion(
                    &mut completions,
                    export,
                    replacement.clone(),
                    &import.spec,
                );
            }
        }

        for item in &import.items {
            let export = exports.get(item).cloned().unwrap_or_else(|| PackageExport {
                name: item.clone(),
                kind: "variable".to_string(),
                documentation: String::new(),
                signature: None,
            });
            insert_package_export_completion(
                &mut completions,
                &export,
                replacement.clone(),
                &import.spec,
            );
        }
    }

    completions.into_values().collect()
}

fn insert_package_export_completion(
    completions: &mut BTreeMap<String, Completion>,
    export: &PackageExport,
    replacement: std::ops::Range<usize>,
    spec: &PackageSpecParts,
) {
    let (insert_text, insert_text_format) = if export.kind == "function" {
        (
            export
                .signature
                .as_ref()
                .map(|_| format!("{}($0)", export.name))
                .unwrap_or_else(|| export.name.clone()),
            export
                .signature
                .as_ref()
                .map(|_| "snippet")
                .unwrap_or("plain_text"),
        )
    } else {
        (export.name.clone(), "plain_text")
    };
    completions.entry(export.name.clone()).or_insert_with(|| Completion {
        label: export.name.clone(),
        detail: format!("{} export", spec.name),
        insert_text,
        insert_text_format: insert_text_format.to_string(),
        replace_start_utf8: replacement.start,
        replace_end_utf8: replacement.end,
        filter_text: export.name.clone(),
        sort_text: export.name.clone(),
        documentation: if export.documentation.is_empty() {
            format!("Imported from {}.", spec.label())
        } else {
            export.documentation.clone()
        },
        kind: export.kind.clone(),
    });
}

fn dot_receiver_before(text: &str, utf8_offset: usize) -> Option<String> {
    let before = text.get(..utf8_offset)?.trim_end();
    let before_dot = before.strip_suffix('.')?;
    let start = before_dot
        .char_indices()
        .rev()
        .find_map(|(index, character)| (!is_typst_identifier_char(character)).then_some(index + character.len_utf8()))
        .unwrap_or(0);
    let receiver = before_dot.get(start..)?.trim();
    (!receiver.is_empty()).then(|| receiver.to_string())
}

fn package_imports_in_text(text: &str) -> Vec<PackageImport> {
    text.lines()
        .filter_map(package_import_from_line)
        .collect::<Vec<_>>()
}

fn package_import_from_line(line: &str) -> Option<PackageImport> {
    let line = strip_line_comment(line);
    let import_start = line.find("#import")?;
    let rest = line.get(import_start + "#import".len()..)?.trim_start();
    let (import_path, suffix) = read_quoted_string(rest)?;
    let spec = parse_package_spec(import_path)?;
    let alias = parse_import_alias(suffix);
    let import_list = suffix.find(':').and_then(|index| suffix.get(index + 1..));
    let wildcard = import_list.is_some_and(|list| list.contains('*'));
    let items = import_list
        .map(parse_import_items)
        .unwrap_or_default()
        .into_iter()
        .filter(|item| item != "*")
        .collect::<Vec<_>>();
    let module_name = alias.or_else(|| import_list.is_none().then(|| spec.name.clone()));

    Some(PackageImport {
        spec,
        module_name,
        wildcard,
        items,
    })
}

fn parse_package_spec(value: &str) -> Option<PackageSpecParts> {
    let value = value.strip_prefix('@')?;
    let (namespace, rest) = value.split_once('/')?;
    let (name, version) = rest.split_once(':')?;
    if namespace.is_empty() || name.is_empty() || version.is_empty() {
        return None;
    }

    Some(PackageSpecParts {
        namespace: namespace.to_string(),
        name: name.to_string(),
        version: version.to_string(),
    })
}

fn package_root_for_spec(
    spec: &PackageSpecParts,
    package_path: &str,
    package_cache_path: &str,
) -> Option<PathBuf> {
    [package_path, package_cache_path]
        .into_iter()
        .map(|root| {
            Path::new(root)
                .join(&spec.namespace)
                .join(&spec.name)
                .join(&spec.version)
        })
        .find(|root| root.join("typst.toml").is_file())
}

fn package_exports(package_root: &Path) -> BTreeMap<String, PackageExport> {
    let entrypoint = package_entrypoint(package_root).unwrap_or_else(|| PathBuf::from("src/lib.typ"));
    let mut visited = HashSet::new();
    collect_exports_from_module(package_root, &entrypoint, &mut visited)
}

fn package_entrypoint(package_root: &Path) -> Option<PathBuf> {
    let manifest = fs::read_to_string(package_root.join("typst.toml")).ok()?;
    read_toml_string_field(&manifest, "entrypoint").map(PathBuf::from)
}

fn read_toml_string_field(text: &str, key: &str) -> Option<String> {
    for line in text.lines() {
        let line = strip_line_comment(line).trim();
        let Some((line_key, value)) = line.split_once('=') else {
            continue;
        };
        if line_key.trim() != key {
            continue;
        }
        let value = value.trim();
        return read_quoted_string(value).map(|(value, _)| value.to_string());
    }
    None
}

fn collect_exports_from_module(
    package_root: &Path,
    module_path: &Path,
    visited: &mut HashSet<PathBuf>,
) -> BTreeMap<String, PackageExport> {
    let absolute_path = package_root.join(module_path);
    let Ok(canonical_path) = absolute_path.canonicalize() else {
        return BTreeMap::new();
    };
    if !visited.insert(canonical_path.clone()) {
        return BTreeMap::new();
    }

    let Ok(text) = fs::read_to_string(&canonical_path) else {
        return BTreeMap::new();
    };
    let current_dir = module_path.parent().unwrap_or_else(|| Path::new(""));
    let mut exports = BTreeMap::<String, PackageExport>::new();
    let mut docs = Vec::<String>::new();

    let mut lines = text.lines().peekable();
    while let Some(line) = lines.next() {
        let stripped = strip_line_comment(line);
        let trimmed = stripped.trim_start();
        if let Some(doc) = trimmed.strip_prefix("///") {
            docs.push(doc.trim().to_string());
            continue;
        }

        if let Some(relative_import) = relative_import_from_line(trimmed) {
            let target = current_dir.join(&relative_import.path);
            let target_exports = collect_exports_from_module(package_root, &target, visited);
            if relative_import.wildcard {
                exports.extend(target_exports.clone());
            }
            for item in relative_import.items {
                if let Some(export) = target_exports.get(&item) {
                    exports.insert(item, export.clone());
                } else {
                    exports.insert(item.clone(), PackageExport {
                        name: item,
                        kind: "variable".to_string(),
                        documentation: String::new(),
                        signature: None,
                    });
                }
            }
            if let Some(module_name) = relative_import.module_name {
                exports.insert(module_name.clone(), PackageExport {
                    name: module_name,
                    kind: "module".to_string(),
                    documentation: String::new(),
                    signature: None,
                });
            }
            docs.clear();
            continue;
        }

        let mut statement = trimmed.to_string();
        if statement.contains("#let") {
            let mut paren_depth = paren_balance(&statement);
            while paren_depth > 0 {
                let Some(next_line) = lines.next() else {
                    break;
                };
                let next_trimmed = strip_line_comment(next_line).trim_start();
                statement.push('\n');
                statement.push_str(next_trimmed);
                paren_depth += paren_balance(next_trimmed);
            }
        }

        if let Some(let_exports) = let_exports_from_statement(&statement, docs.join("\n")) {
            for export in let_exports {
                exports.insert(export.name.clone(), export);
            }
            docs.clear();
            continue;
        }

        if !trimmed.is_empty() {
            docs.clear();
        }
    }

    exports
}

#[derive(Debug)]
struct RelativeImport {
    path: PathBuf,
    module_name: Option<String>,
    wildcard: bool,
    items: Vec<String>,
}

fn relative_import_from_line(line: &str) -> Option<RelativeImport> {
    let import_start = line.find("#import")?;
    let rest = line.get(import_start + "#import".len()..)?.trim_start();
    let (import_path, suffix) = read_quoted_string(rest)?;
    if import_path.starts_with('@') {
        return None;
    }
    let alias = parse_import_alias(suffix);
    let import_list = suffix.find(':').and_then(|index| suffix.get(index + 1..));
    let wildcard = import_list.is_some_and(|list| list.contains('*'));
    let items = import_list
        .map(parse_import_items)
        .unwrap_or_default()
        .into_iter()
        .filter(|item| item != "*")
        .collect::<Vec<_>>();
    let module_name = alias.or_else(|| import_list.is_none().then(|| module_name_for_import_path(import_path)));

    Some(RelativeImport {
        path: PathBuf::from(import_path),
        module_name,
        wildcard,
        items,
    })
}

fn let_exports_from_statement(statement: &str, documentation: String) -> Option<Vec<PackageExport>> {
    let start = statement.find("#let")?;
    let mut rest = statement.get(start + "#let".len()..)?.trim_start();
    if rest.starts_with('(') {
        rest = rest.get(1..)?;
        let end = rest.find(')')?;
        let names = rest.get(..end)?;
        let exports = names
            .split(',')
            .filter_map(|item| {
                let name = item.trim();
                is_export_name(name).then(|| PackageExport {
                    name: name.to_string(),
                    kind: "variable".to_string(),
                    documentation: documentation.clone(),
                    signature: None,
                })
            })
            .collect::<Vec<_>>();
        return (!exports.is_empty()).then_some(exports);
    }

    let name_end = rest
        .char_indices()
        .find_map(|(index, character)| (!is_typst_identifier_char(character)).then_some(index))
        .unwrap_or(rest.len());
    let name = rest.get(..name_end)?;
    if !is_export_name(name) {
        return None;
    }
    let after_name = rest.get(name_end..).unwrap_or("").trim_start();
    let signature = function_signature(name, after_name);
    let kind = if signature.is_some() {
        "function"
    } else {
        "variable"
    };

    Some(vec![PackageExport {
        name: name.to_string(),
        kind: kind.to_string(),
        documentation,
        signature,
    }])
}

fn paren_balance(text: &str) -> i32 {
    let mut depth = 0;
    let mut in_string = false;
    let mut in_raw = false;
    let mut escaped = false;
    for character in text.chars() {
        if escaped {
            escaped = false;
            continue;
        }
        if character == '\\' && in_string {
            escaped = true;
            continue;
        }
        if character == '"' && !in_raw {
            in_string = !in_string;
            continue;
        }
        if character == '`' && !in_string {
            in_raw = !in_raw;
            continue;
        }
        if in_string || in_raw {
            continue;
        }
        match character {
            '(' => depth += 1,
            ')' => depth -= 1,
            _ => {}
        }
    }
    depth
}

fn function_signature(name: &str, after_name: &str) -> Option<PackageSignature> {
    let parameters_text = balanced_parenthesized_content(after_name.trim_start())?;
    let parameters = split_top_level_commas(parameters_text)
        .into_iter()
        .filter_map(parameter_label)
        .collect::<Vec<_>>();
    Some(PackageSignature {
        label: format!("{}({})", name, parameters.join(", ")),
        parameters,
    })
}

fn balanced_parenthesized_content(text: &str) -> Option<&str> {
    let text = text.strip_prefix('(')?;
    let mut depth = 1;
    let mut in_string = false;
    let mut in_raw = false;
    let mut escaped = false;
    for (index, character) in text.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if character == '\\' && in_string {
            escaped = true;
            continue;
        }
        if character == '"' && !in_raw {
            in_string = !in_string;
            continue;
        }
        if character == '`' && !in_string {
            in_raw = !in_raw;
            continue;
        }
        if in_string || in_raw {
            continue;
        }
        match character {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    return text.get(..index);
                }
            }
            _ => {}
        }
    }
    None
}

fn split_top_level_commas(text: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut start = 0;
    let mut paren_depth = 0;
    let mut bracket_depth = 0;
    let mut brace_depth = 0;
    let mut in_string = false;
    let mut in_raw = false;
    let mut escaped = false;
    for (index, character) in text.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if character == '\\' && in_string {
            escaped = true;
            continue;
        }
        if character == '"' && !in_raw {
            in_string = !in_string;
            continue;
        }
        if character == '`' && !in_string {
            in_raw = !in_raw;
            continue;
        }
        if in_string || in_raw {
            continue;
        }
        match character {
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            '[' => bracket_depth += 1,
            ']' => bracket_depth -= 1,
            '{' => brace_depth += 1,
            '}' => brace_depth -= 1,
            ',' if paren_depth == 0 && bracket_depth == 0 && brace_depth == 0 => {
                parts.push(text.get(start..index).unwrap_or("").trim());
                start = index + character.len_utf8();
            }
            _ => {}
        }
    }
    parts.push(text.get(start..).unwrap_or("").trim());
    parts
}

fn parameter_label(parameter: &str) -> Option<String> {
    let parameter = parameter.trim();
    if parameter.is_empty() {
        return None;
    }
    if parameter.starts_with("..") {
        let name = parameter
            .chars()
            .take_while(|character| *character == '.' || is_typst_identifier_char(*character))
            .collect::<String>();
        return (!name.is_empty()).then_some(name);
    }
    let name = parameter
        .split_once(':')
        .map(|(name, _)| name)
        .unwrap_or(parameter)
        .trim();
    is_export_name(name).then(|| name.to_string())
}

fn parse_import_alias(suffix: &str) -> Option<String> {
    let suffix = suffix.trim_start();
    let suffix = suffix.strip_prefix("as")?;
    if suffix
        .chars()
        .next()
        .is_some_and(is_typst_identifier_char)
    {
        return None;
    }
    let suffix = suffix.trim_start();
    let end = suffix
        .char_indices()
        .find_map(|(index, character)| (!is_typst_identifier_char(character)).then_some(index))
        .unwrap_or(suffix.len());
    let alias = suffix.get(..end)?;
    is_export_name(alias).then(|| alias.to_string())
}

fn parse_import_items(list: &str) -> Vec<String> {
    list.split(',')
        .filter_map(|item| {
            let name = item
                .trim()
                .trim_matches(|character: char| character == '(' || character == ')')
                .split('.')
                .next()
                .unwrap_or("")
                .trim();
            (name == "*" || is_export_name(name)).then(|| name.to_string())
        })
        .collect()
}

fn module_name_for_import_path(path: &str) -> String {
    Path::new(path)
        .file_stem()
        .and_then(|name| name.to_str())
        .unwrap_or(path)
        .to_string()
}

fn read_quoted_string(text: &str) -> Option<(&str, &str)> {
    let text = text.trim_start();
    let text = text.strip_prefix('"')?;
    let mut escaped = false;
    for (index, character) in text.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if character == '\\' {
            escaped = true;
            continue;
        }
        if character == '"' {
            let value = text.get(..index)?;
            let suffix = text.get(index + 1..)?;
            return Some((value, suffix));
        }
    }
    None
}

fn strip_line_comment(line: &str) -> &str {
    line.split_once("//")
        .map(|(before, _)| before)
        .unwrap_or(line)
}

fn is_export_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('_')
        && name.chars().all(is_typst_identifier_char)
        && name
            .chars()
            .next()
            .is_some_and(|character| character.is_ascii_alphabetic() || character == '_')
}

fn is_typst_identifier_char(character: char) -> bool {
    character.is_ascii_alphanumeric() || character == '_' || character == '-'
}

fn workspace_file_paths(root: &str) -> Vec<String> {
    let root = PathBuf::from(root);
    let mut paths = Vec::new();
    collect_workspace_file_paths(&root, &root, &mut paths);
    paths.sort();
    paths
}

fn collect_workspace_file_paths(root: &Path, directory: &Path, paths: &mut Vec<String>) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_workspace_file_paths(root, &path, paths);
        } else if path.is_file() {
            if let Ok(relative) = path.strip_prefix(root) {
                let package_path = relative
                    .components()
                    .map(|component| component.as_os_str().to_string_lossy())
                    .collect::<Vec<_>>()
                    .join("/");
                if !package_path.is_empty() && !package_path.starts_with('.') {
                    paths.push(package_path);
                }
            }
        }
    }
}

fn completion_replacement_range(text: &str, utf8_offset: usize) -> std::ops::Range<usize> {
    let bytes = text.as_bytes();
    let mut start = utf8_offset;
    while start > 0 && is_word_byte(bytes[start - 1]) {
        start -= 1;
    }
    start..utf8_offset
}

fn clamp_to_char_boundary(text: &str, utf8_offset: usize) -> usize {
    let mut offset = utf8_offset.min(text.len());
    while offset > 0 && !text.is_char_boundary(offset) {
        offset -= 1;
    }
    offset
}

fn hover_for(text: &str, utf8_offset: usize) -> Option<Hover> {
    let bytes = text.as_bytes();
    if utf8_offset > bytes.len() {
        return None;
    }

    let mut start = utf8_offset;
    while start > 0 && is_word_byte(bytes[start - 1]) {
        start -= 1;
    }

    let mut end = utf8_offset;
    while end < bytes.len() && is_word_byte(bytes[end]) {
        end += 1;
    }

    if start == end {
        return None;
    }

    if !is_hover_code_context(text, start) {
        return None;
    }

    let word = &text[start..end];
    Some(Hover {
        start_utf8: start,
        end_utf8: end,
        text: format!("Typst symbol `{word}`"),
    })
}

struct FunctionCallContext {
    function_name: String,
    active_parameter: usize,
}

fn signature_help_for(
    text: &str,
    utf8_offset: usize,
    package_path: &str,
    package_cache_path: &str,
) -> Option<SignatureHelp> {
    let Some(context) = function_call_context(text, clamp_to_char_boundary(text, utf8_offset)) else {
        lsp_debug("signature branch=no function call context");
        return None;
    };
    lsp_debug(format!(
        "signature function='{}' active_parameter={}",
        context.function_name, context.active_parameter
    ));
    let export = package_export_for_function(
        text,
        &context.function_name,
        package_path,
        package_cache_path,
    )?;
    let Some(signature) = export.signature else {
        lsp_debug(format!(
            "signature export '{}' had no inferred signature",
            export.name
        ));
        return None;
    };
    let active_parameter = context
        .active_parameter
        .min(signature.parameters.len().saturating_sub(1));
    Some(SignatureHelp {
        signatures: vec![SignatureInformation {
            label: signature.label,
            documentation: export.documentation,
            parameters: signature
                .parameters
                .into_iter()
                .map(|label| ParameterInformation {
                    label,
                    documentation: String::new(),
                })
                .collect(),
        }],
        active_signature: 0,
        active_parameter,
    })
}

fn function_call_context(text: &str, utf8_offset: usize) -> Option<FunctionCallContext> {
    let prefix = text.get(..utf8_offset)?;
    let mut stack = Vec::<(usize, usize)>::new();
    let mut in_string = false;
    let mut in_raw = false;
    let mut escaped = false;

    for (index, character) in prefix.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if character == '\\' && in_string {
            escaped = true;
            continue;
        }
        if character == '"' && !in_raw {
            in_string = !in_string;
            continue;
        }
        if character == '`' && !in_string {
            in_raw = !in_raw;
            continue;
        }
        if in_string || in_raw {
            continue;
        }
        match character {
            '(' => stack.push((index, 0)),
            ')' => {
                stack.pop();
            }
            ',' => {
                if let Some((_, active_parameter)) = stack.last_mut() {
                    *active_parameter += 1;
                }
            }
            _ => {}
        }
    }

    let (open_paren, active_parameter) = stack.last().copied()?;
    let function_name = function_name_before_open_paren(text, open_paren)?;
    Some(FunctionCallContext {
        function_name,
        active_parameter,
    })
}

fn function_name_before_open_paren(text: &str, open_paren: usize) -> Option<String> {
    let before = text.get(..open_paren)?.trim_end();
    let start = before
        .char_indices()
        .rev()
        .find_map(|(index, character)| {
            (!(is_typst_identifier_char(character) || character == '.'))
                .then_some(index + character.len_utf8())
        })
        .unwrap_or(0);
    let name = before.get(start..)?.trim();
    (!name.is_empty()).then(|| name.to_string())
}

fn package_export_for_function(
    text: &str,
    function_name: &str,
    package_path: &str,
    package_cache_path: &str,
) -> Option<PackageExport> {
    let (receiver, member) = function_name
        .rsplit_once('.')
        .map(|(receiver, member)| (Some(receiver), member))
        .unwrap_or((None, function_name));
    let imports = package_imports_in_text(text);
    lsp_debug(format!(
        "signature package lookup function='{function_name}' receiver={receiver:?} member='{member}' imports={}",
        imports.len()
    ));

    for import in imports {
        let Some(package_root) = package_root_for_spec(&import.spec, package_path, package_cache_path)
        else {
            lsp_debug(format!(
                "signature root missing spec={} local='{}' cache='{}'",
                import.spec.label(),
                package_path,
                package_cache_path
            ));
            continue;
        };
        let exports = package_exports(&package_root);
        lsp_debug(format!(
            "signature inspect spec={} exports={} module={:?} wildcard={} items={:?}",
            import.spec.label(),
            exports.len(),
            import.module_name,
            import.wildcard,
            import.items
        ));

        if let Some(receiver) = receiver {
            if import.module_name.as_deref() == Some(receiver) {
                if let Some(export) = exports.get(member) {
                    return Some(export.clone());
                }
            }
            continue;
        }

        if import.wildcard || import.items.iter().any(|item| item == member) {
            if let Some(export) = exports.get(member) {
                return Some(export.clone());
            }
        }
    }
    lsp_debug(format!(
        "signature package lookup missed function='{function_name}'"
    ));
    None
}

fn is_hover_code_context(text: &str, utf8_offset: usize) -> bool {
    let clamped = utf8_offset.min(text.len());
    let line_start = text[..clamped].rfind('\n').map_or(0, |index| index + 1);
    let prefix = &text[line_start..clamped];
    let trimmed_prefix = prefix.trim_start_matches(char::is_whitespace);

    if trimmed_prefix.starts_with('#') || trimmed_prefix.starts_with("//") {
        return true;
    }
    if prefix.contains('#') || prefix.contains('@') {
        return true;
    }

    prefix
        .bytes()
        .rev()
        .find(|byte| !byte.is_ascii_whitespace())
        .is_some_and(|byte| matches!(byte, b'#' | b'.' | b'@' | b'<'))
}

fn prose_ranges_for(text: &str, ignore_commands: bool) -> Vec<ProseRange> {
    let root = parse(text);
    let mut blocked = Vec::new();
    collect_non_prose(&root, 0, ignore_commands, &mut blocked);
    collect_quoted_non_prose(text, &mut blocked);
    blocked.sort_by_key(|range| range.start);

    let mut ranges = Vec::new();
    let mut cursor = 0;
    for block in blocked {
        if cursor < block.start {
            ranges.push(ProseRange {
                start_utf8: cursor,
                end_utf8: block.start,
            });
        }
        cursor = cursor.max(block.end);
    }
    if cursor < text.len() {
        ranges.push(ProseRange {
            start_utf8: cursor,
            end_utf8: text.len(),
        });
    }
    ranges
}

fn collect_quoted_non_prose(text: &str, ranges: &mut Vec<std::ops::Range<usize>>) {
    let bytes = text.as_bytes();
    let mut index = 0;
    let mut double_quote_start: Option<usize> = None;
    let mut backtick_start: Option<usize> = None;

    while index < bytes.len() {
        match bytes[index] {
            b'"' if backtick_start.is_none() && !is_escaped_quote(bytes, index) => {
                if let Some(start) = double_quote_start.take() {
                    ranges.push(start..index + 1);
                } else {
                    double_quote_start = Some(index);
                }
            }
            b'`' if double_quote_start.is_none() => {
                if let Some(start) = backtick_start.take() {
                    ranges.push(start..index + 1);
                } else {
                    backtick_start = Some(index);
                }
            }
            _ => {}
        }
        index += 1;
    }

    if let Some(start) = double_quote_start {
        ranges.push(start..bytes.len());
    }
    if let Some(start) = backtick_start {
        ranges.push(start..bytes.len());
    }
}

fn is_escaped_quote(bytes: &[u8], quote_index: usize) -> bool {
    let mut slash_count = 0;
    let mut index = quote_index;
    while index > 0 {
        index -= 1;
        if bytes[index] == b'\\' {
            slash_count += 1;
        } else {
            break;
        }
    }
    slash_count % 2 == 1
}

fn collect_non_prose(
    node: &SyntaxNode,
    offset: usize,
    ignore_commands: bool,
    ranges: &mut Vec<std::ops::Range<usize>>,
) {
    match node.kind() {
        SyntaxKind::Code
        | SyntaxKind::CodeBlock
        | SyntaxKind::Math
        | SyntaxKind::Raw
        | SyntaxKind::LineComment
        | SyntaxKind::BlockComment => {
            ranges.push(offset..offset + node.len());
            return;
        }
        _ => {}
    }

    if ignore_commands
        && matches!(
            node.kind(),
            SyntaxKind::FuncCall
                | SyntaxKind::Args
                | SyntaxKind::SetRule
                | SyntaxKind::ShowRule
                | SyntaxKind::LetBinding
                | SyntaxKind::ModuleImport
                | SyntaxKind::ModuleInclude
        )
    {
        ranges.push(offset..offset + node.len());
        return;
    }

    let mut child_offset = offset;
    for child in node.children() {
        collect_non_prose(&child, child_offset, ignore_commands, ranges);
        child_offset += child.len();
    }
}

fn is_word_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-'
}

fn document_symbols_for(text: &str) -> DocumentSymbolsResponse {
    let root = parse(text);
    let mut outline = Vec::new();
    let mut figures = Vec::new();
    collect_symbols(&root, 0, text, &mut outline, &mut figures);

    let mut labels: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    let mut uses: BTreeMap<String, Vec<(usize, usize)>> = BTreeMap::new();
    collect_references(&root, 0, text, &mut labels, &mut uses);
    let references = build_reference_groups(labels, uses);

    DocumentSymbolsResponse {
        outline,
        figures,
        references,
    }
}

fn collect_references(
    node: &SyntaxNode,
    offset: usize,
    text: &str,
    labels: &mut BTreeMap<String, (usize, usize)>,
    uses: &mut BTreeMap<String, Vec<(usize, usize)>>,
) {
    let end = offset + node.len();
    match node.kind() {
        SyntaxKind::Label => {
            let raw = text.get(offset..end).unwrap_or("");
            let name = raw.trim_start_matches('<').trim_end_matches('>').to_string();
            if !name.is_empty() {
                labels.entry(name).or_insert((offset, end));
            }
        }
        SyntaxKind::Ref => {
            let raw = text.get(offset..end).unwrap_or("");
            if let Some(name) = ref_target_name(raw) {
                uses.entry(name).or_default().push((offset, end));
            }
        }
        _ => {}
    }

    let mut child_offset = offset;
    for child in node.children() {
        collect_references(child, child_offset, text, labels, uses);
        child_offset += child.len();
    }
}

fn ref_target_name(raw: &str) -> Option<String> {
    let rest = raw.strip_prefix('@')?;
    let name: String = rest
        .chars()
        .take_while(|character| {
            character.is_alphanumeric()
                || matches!(*character, '_' | '-' | '.' | ':')
        })
        .collect();
    (!name.is_empty()).then_some(name)
}

fn build_reference_groups(
    labels: BTreeMap<String, (usize, usize)>,
    uses: BTreeMap<String, Vec<(usize, usize)>>,
) -> Vec<ReferenceGroup> {
    let mut names: HashSet<String> = HashSet::new();
    names.extend(labels.keys().cloned());
    names.extend(uses.keys().cloned());

    let mut groups: Vec<ReferenceGroup> = names
        .into_iter()
        .map(|name| {
            let source = labels.get(&name).copied();
            let group_uses = uses
                .get(&name)
                .map(|ranges| {
                    ranges
                        .iter()
                        .map(|(start, end)| SymbolRange {
                            start_utf8: *start,
                            end_utf8: *end,
                        })
                        .collect()
                })
                .unwrap_or_default();
            ReferenceGroup {
                name,
                has_source: source.is_some(),
                source_start_utf8: source.map(|(start, _)| start).unwrap_or(0),
                source_end_utf8: source.map(|(_, end)| end).unwrap_or(0),
                uses: group_uses,
            }
        })
        .collect();

    groups.sort_by_key(|group| {
        let source_position = if group.has_source {
            group.source_start_utf8
        } else {
            usize::MAX
        };
        let first_use = group
            .uses
            .first()
            .map(|range| range.start_utf8)
            .unwrap_or(usize::MAX);
        source_position.min(first_use)
    });
    groups
}

fn collect_symbols(
    node: &SyntaxNode,
    offset: usize,
    text: &str,
    outline: &mut Vec<OutlineItem>,
    figures: &mut Vec<FigureItem>,
) {
    match node.kind() {
        SyntaxKind::Heading => {
            let end = offset + node.len();
            let raw = text.get(offset..end).unwrap_or("");
            let level = raw.chars().take_while(|character| *character == '=').count().max(1);
            let title = strip_trailing_label(raw.trim_start_matches('=').trim());
            outline.push(OutlineItem {
                title,
                level,
                start_utf8: offset,
                end_utf8: end,
            });
        }
        SyntaxKind::FuncCall => {
            if let Some(name) = func_call_name(node) {
                if name == "figure" || name == "table" {
                    let end = offset + node.len();
                    let raw = text.get(offset..end).unwrap_or("");
                    let kind = if name == "table" || raw.contains("table(") {
                        "table"
                    } else {
                        "figure"
                    };
                    let caption = extract_caption(raw).filter(|caption| !caption.is_empty());
                    let label = trailing_label_after(text, end);
                    let title = caption.unwrap_or_else(|| {
                        if !label.is_empty() {
                            label.clone()
                        } else if kind == "table" {
                            "Table".to_string()
                        } else {
                            "Figure".to_string()
                        }
                    });
                    figures.push(FigureItem {
                        title,
                        kind: kind.to_string(),
                        label,
                        start_utf8: offset,
                        end_utf8: end,
                    });
                    // Don't descend: a table or image wrapped in this figure
                    // shouldn't be listed a second time.
                    return;
                }
            }
        }
        _ => {}
    }

    let mut child_offset = offset;
    for child in node.children() {
        collect_symbols(child, child_offset, text, outline, figures);
        child_offset += child.len();
    }
}

fn func_call_name(node: &SyntaxNode) -> Option<String> {
    for child in node.children() {
        match child.kind() {
            SyntaxKind::Ident => return Some(child.text().to_string()),
            SyntaxKind::FieldAccess => return field_access_last_ident(child),
            SyntaxKind::Args => break,
            _ => {}
        }
    }
    None
}

fn field_access_last_ident(node: &SyntaxNode) -> Option<String> {
    let mut last = None;
    for child in node.children() {
        if child.kind() == SyntaxKind::Ident {
            last = Some(child.text().to_string());
        }
    }
    last
}

fn extract_caption(raw: &str) -> Option<String> {
    let index = raw.find("caption:")?;
    let after = raw.get(index + "caption:".len()..)?.trim_start();
    if let Some(rest) = after.strip_prefix('[') {
        Some(clean_caption_text(balanced_content(rest, b'[', b']')))
    } else if after.starts_with('"') {
        read_quoted_string(after).map(|(value, _)| value.to_string())
    } else {
        None
    }
}

fn balanced_content(text: &str, open: u8, close: u8) -> &str {
    let bytes = text.as_bytes();
    let mut depth = 1usize;
    let mut index = 0usize;
    while index < bytes.len() {
        match bytes[index] {
            b'\\' => {
                index += 2;
                continue;
            }
            byte if byte == open => depth += 1,
            byte if byte == close => {
                depth -= 1;
                if depth == 0 {
                    return &text[..index];
                }
            }
            _ => {}
        }
        index += 1;
    }
    text
}

fn clean_caption_text(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn strip_trailing_label(title: &str) -> String {
    let trimmed = title.trim_end();
    if trimmed.ends_with('>') {
        if let Some(open) = trimmed.rfind('<') {
            return trimmed[..open].trim_end().to_string();
        }
    }
    trimmed.to_string()
}

fn trailing_label_after(text: &str, end: usize) -> String {
    let after = text.get(end..).unwrap_or("");
    let trimmed = after.trim_start_matches([' ', '\t']);
    if let Some(rest) = trimmed.strip_prefix('<') {
        if let Some(close) = rest.find('>') {
            return rest[..close].to_string();
        }
    }
    String::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn single_file(text: &str) -> HashMap<String, String> {
        let mut files = HashMap::new();
        files.insert("main.typ".to_string(), text.to_string());
        files
    }

    fn test_completions_for(text: &str, offset: usize, paths: &[String]) -> Vec<Completion> {
        completions_for(text, offset, paths, "", "", &single_file(text), "main.typ")
    }

    #[test]
    fn reports_parse_diagnostics() {
        let diagnostics = syntax_diagnostics("main.typ", "#let x = ");
        assert!(!diagnostics.is_empty());
    }

    #[test]
    fn returns_completions() {
        assert!(!test_completions_for("#", 1, &[]).is_empty());
    }

    #[test]
    fn completion_replaces_command_prefix_without_hash() {
        let completions = test_completions_for("#im", 3, &[]);
        let image = completions
            .into_iter()
            .find(|completion| completion.label == "image")
            .unwrap();

        // The autocomplete engine inserts a call snippet and replaces only the
        // typed identifier (`im`), leaving the leading `#` intact.
        assert!(image.insert_text.starts_with("image("));
        assert_eq!(image.insert_text_format, "snippet");
        assert_eq!(image.replace_start_utf8, 1);
        assert_eq!(image.replace_end_utf8, 3);
    }

    #[test]
    fn completes_standard_library_functions_in_code_context() {
        // Regression: `#tex` used to offer nothing, so the editor flagged `tex`
        // as an unknown variable instead of suggesting `text`. The real
        // autocomplete engine now offers the whole standard library.
        let completions = test_completions_for("#tex", 4, &[]);
        let text = completions
            .into_iter()
            .find(|completion| completion.label == "text")
            .expect("text() should be offered as a completion");

        assert!(text.insert_text.starts_with("text("));
        assert_eq!(text.insert_text_format, "snippet");
        assert_eq!(text.replace_start_utf8, 1);
        assert_eq!(text.replace_end_utf8, 4);
    }

    #[test]
    fn completes_local_let_bindings() {
        // The autocomplete engine resolves user-defined bindings, which the old
        // hardcoded list never could.
        let text = "#let theorem = 1\n#theo";
        let completions = test_completions_for(text, text.len(), &[]);
        assert!(
            completions
                .iter()
                .any(|completion| completion.label == "theorem"),
            "a local #let binding should be offered as a completion"
        );
    }

    #[test]
    fn completes_keywords_in_code_context() {
        // Keywords come from the engine's grammar-aware code completions.
        let completions = test_completions_for("#imp", 4, &[]);
        assert!(
            completions
                .iter()
                .any(|completion| completion.label.starts_with("import")),
            "import should be offered after `#imp`"
        );
    }

    #[test]
    fn does_not_offer_library_functions_in_plain_prose() {
        // Markup prose stays clean — typing a word must not suggest functions.
        let completions = test_completions_for("the text", 3, &[]);
        assert!(
            !completions.iter().any(|completion| completion.label == "text"),
            "plain prose should not surface library function completions"
        );
    }

    #[test]
    fn extracts_outline_and_figures() {
        let text = "= Intro\n\nBody text.\n\n== Details <sec:d>\n\n#figure(image(\"a.png\"), caption: [A picture]) <fig:a>\n\n#figure(table(columns: 2), caption: [A table]) <tab:b>\n";
        let symbols = document_symbols_for(text);

        assert_eq!(symbols.outline.len(), 2);
        assert_eq!(symbols.outline[0].title, "Intro");
        assert_eq!(symbols.outline[0].level, 1);
        assert_eq!(symbols.outline[1].title, "Details");
        assert_eq!(symbols.outline[1].level, 2);

        assert_eq!(symbols.figures.len(), 2);
        assert_eq!(symbols.figures[0].title, "A picture");
        assert_eq!(symbols.figures[0].kind, "figure");
        assert_eq!(symbols.figures[0].label, "fig:a");
        assert_eq!(symbols.figures[1].title, "A table");
        assert_eq!(symbols.figures[1].kind, "table");
        assert_eq!(symbols.figures[1].label, "tab:b");

        // The text body before the first heading offset is correct.
        assert!(symbols.outline[0].start_utf8 < symbols.outline[1].start_utf8);
    }

    #[test]
    fn groups_references_by_label() {
        let text = "= Intro <sec:intro>\n\nSee @sec:intro and also @sec:intro.\n\nA dangling @missing reference.\n";
        let symbols = document_symbols_for(text);

        let intro = symbols
            .references
            .iter()
            .find(|group| group.name == "sec:intro")
            .expect("sec:intro group");
        assert!(intro.has_source);
        assert_eq!(intro.uses.len(), 2);

        let missing = symbols
            .references
            .iter()
            .find(|group| group.name == "missing")
            .expect("missing group");
        assert!(!missing.has_source);
        assert_eq!(missing.uses.len(), 1);
    }

    #[test]
    fn plain_prose_offers_no_completions() {
        // A bare word in markup (no `#`) is prose, not code — the engine offers
        // nothing so completions never pop up mid-sentence.
        assert!(test_completions_for("im", 2, &[]).is_empty());
    }

    #[test]
    fn completes_field_access_methods() {
        // Field access is resolved by evaluating the receiver — `calc` is the
        // standard-library math module, so `calc.ab` offers `abs`.
        let text = "#calc.ab";
        let completions = test_completions_for(text, text.len(), &[]);
        assert!(
            completions
                .iter()
                .any(|completion| completion.label == "abs"),
            "calc.ab should offer the `abs` field"
        );
    }

    #[test]
    fn completion_keeps_code_prefix_without_hash_command() {
        let text = "#let x = im";
        let completions = test_completions_for(text, text.len(), &[]);
        let image = completions
            .into_iter()
            .find(|completion| completion.label == "image")
            .unwrap();

        assert!(image.insert_text.starts_with("image("));
        assert_eq!(image.insert_text_format, "snippet");
        assert_eq!(image.replace_start_utf8, 9);
        assert_eq!(image.replace_end_utf8, 11);
    }

    #[test]
    fn completes_image_paths_inside_image_call() {
        let paths = vec![
            "Images/Atom.svg".to_string(),
            "chapters/intro.typ".to_string(),
        ];
        let text = "#image(\"Im\")";
        let completions = test_completions_for(text, 10, &paths);

        assert_eq!(completions.len(), 1);
        assert_eq!(completions[0].label, "Images/Atom.svg");
        assert_eq!(completions[0].replace_start_utf8, 8);
        assert_eq!(completions[0].replace_end_utf8, 10);
    }

    #[test]
    fn completes_typst_paths_inside_include_call() {
        let paths = vec![
            "Images/Atom.svg".to_string(),
            "chapters/intro.typ".to_string(),
        ];
        let text = "#include \"chap\"";
        let completions = test_completions_for(text, 14, &paths);

        assert_eq!(completions.len(), 1);
        assert_eq!(completions[0].label, "chapters/intro.typ");
        assert_eq!(completions[0].replace_start_utf8, 10);
        assert_eq!(completions[0].replace_end_utf8, 14);
    }

    #[test]
    fn completes_installed_package_specs_inside_import_string() {
        let (_local, cache) = test_package_storage();
        write_test_package(&cache);
        let text = "#import \"@pre";
        let completions = completions_for(
            text,
            text.len(),
            &[],
            "",
            cache.to_str().unwrap(),
            &single_file(text),
            "main.typ",
        );

        assert!(completions
            .iter()
            .any(|completion| completion.label == "@preview/fletcher:0.5.8"));
    }

    #[test]
    fn completes_exports_from_wildcard_package_import() {
        let (_local, cache) = test_package_storage();
        write_test_package(&cache);
        let text = "#import \"@preview/fletcher:0.5.8\": *\n#di";
        let completions = completions_for(
            text,
            text.len(),
            &[],
            "",
            cache.to_str().unwrap(),
            &single_file(text),
            "main.typ",
        );
        let diagram = completions
            .iter()
            .find(|completion| completion.label == "diagram")
            .unwrap();

        assert_eq!(diagram.kind, "function");
        assert_eq!(diagram.insert_text, "diagram($0)");
        assert_eq!(diagram.replace_start_utf8, text.len() - 2);
        assert_eq!(diagram.replace_end_utf8, text.len());
    }

    #[test]
    fn completes_exports_inside_package_import_list() {
        let (_local, cache) = test_package_storage();
        write_test_package(&cache);
        let text = "#import \"@preview/fletcher:0.5.8\": di";
        let completions = completions_for(
            text,
            text.len(),
            &[],
            "",
            cache.to_str().unwrap(),
            &single_file(text),
            "main.typ",
        );
        let diagram = completions
            .iter()
            .find(|completion| completion.label == "diagram")
            .unwrap();

        assert_eq!(diagram.insert_text, "diagram");
        assert_eq!(diagram.insert_text_format, "plain_text");
        assert_eq!(diagram.replace_start_utf8, text.len() - 2);
        assert_eq!(diagram.replace_end_utf8, text.len());
    }

    #[test]
    fn completes_explicitly_imported_package_symbols() {
        let (_local, cache) = test_package_storage();
        write_test_package(&cache);
        let text = "#import \"@preview/fletcher:0.5.8\" as fletcher: diagram, node\n#no";
        let completions = completions_for(
            text,
            text.len(),
            &[],
            "",
            cache.to_str().unwrap(),
            &single_file(text),
            "main.typ",
        );

        assert!(completions
            .iter()
            .any(|completion| completion.label == "node"));
    }

    #[test]
    fn completes_exports_from_package_module_alias() {
        let (_local, cache) = test_package_storage();
        write_test_package(&cache);
        let text = "#import \"@preview/fletcher:0.5.8\" as fletcher\n#fletcher.di";
        let completions = completions_for(
            text,
            text.len(),
            &[],
            "",
            cache.to_str().unwrap(),
            &single_file(text),
            "main.typ",
        );

        assert!(completions
            .iter()
            .any(|completion| completion.label == "diagram"));
    }

    #[test]
    fn returns_signature_help_for_imported_package_function() {
        let (_local, cache) = test_package_storage();
        write_test_package(&cache);
        let text = "#import \"@preview/fletcher:0.5.8\": *\n#diagram(";
        let signature =
            signature_help_for(text, text.len(), "", cache.to_str().unwrap()).unwrap();

        assert_eq!(signature.signatures[0].label, "diagram(..children)");
        assert_eq!(signature.signatures[0].parameters[0].label, "..children");
    }

    #[test]
    fn returns_signature_help_for_package_alias_function() {
        let (_local, cache) = test_package_storage();
        write_test_package(&cache);
        let text = "#import \"@preview/fletcher:0.5.8\" as fletcher\n#fletcher.diagram(";
        let signature =
            signature_help_for(text, text.len(), "", cache.to_str().unwrap()).unwrap();

        assert_eq!(signature.signatures[0].label, "diagram(..children)");
    }

    fn test_package_storage() -> (PathBuf, PathBuf) {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("typeset-tinymist-test-{stamp}"));
        let local = root.join("local");
        let cache = root.join("cache");
        fs::create_dir_all(&local).unwrap();
        fs::create_dir_all(&cache).unwrap();
        (local, cache)
    }

    fn write_test_package(cache: &Path) {
        let package = cache.join("preview/fletcher/0.5.8");
        fs::create_dir_all(package.join("src")).unwrap();
        fs::write(
            package.join("typst.toml"),
            r#"
[package]
name = "fletcher"
version = "0.5.8"
entrypoint = "src/exports.typ"
description = "Draw diagrams."
"#,
        )
        .unwrap();
        fs::write(
            package.join("src/exports.typ"),
            r#"
#import "diagram.typ": *
#import "node.typ": node
#import "shapes.typ"
"#,
        )
        .unwrap();
        fs::write(
            package.join("src/diagram.typ"),
            r#"
/// Draw a diagram.
#let diagram(
  ..children,
) = children
"#,
        )
        .unwrap();
        fs::write(package.join("src/node.typ"), "#let node(body) = body\n").unwrap();
        fs::write(package.join("src/shapes.typ"), "#let circle() = none\n").unwrap();
    }

    #[test]
    fn returns_hover() {
        let hover = hover_for("#image(\"a.png\")", 3).unwrap();
        assert_eq!(hover.text, "Typst symbol `image`");
    }

    #[test]
    fn suppresses_plain_text_hover() {
        assert!(hover_for("This is plain text", 11).is_none());
    }

    #[test]
    fn excludes_code_from_prose_ranges() {
        let ranges = prose_ranges_for("Hello #let x = 1\nWorld", true);
        assert!(!ranges.is_empty());
    }

    #[test]
    fn excludes_quoted_text_from_prose_ranges() {
        let text = "Spell prose but not \"mispelled string\" or `mispelled raw` here";
        let ranges = prose_ranges_for(text, true);
        let prose = ranges
            .into_iter()
            .map(|range| &text[range.start_utf8..range.end_utf8])
            .collect::<Vec<_>>()
            .join("");

        assert!(prose.contains("Spell prose"));
        assert!(prose.contains(" here"));
        assert!(!prose.contains("mispelled string"));
        assert!(!prose.contains("mispelled raw"));
    }

    #[test]
    fn excludes_command_invocations_from_prose_ranges() {
        let text = "Spell prose #link(\"https://example.com\")[mispelled argument] and catch typoo";
        let ranges = prose_ranges_for(text, true);
        let prose = ranges
            .into_iter()
            .map(|range| &text[range.start_utf8..range.end_utf8])
            .collect::<Vec<_>>()
            .join("");

        assert!(prose.contains("Spell prose"));
        assert!(prose.contains("and catch typoo"));
        assert!(!prose.contains("link"));
        assert!(!prose.contains("mispelled argument"));
    }

    #[test]
    fn can_include_command_invocations_in_prose_ranges() {
        let text = "Spell prose #link(\"https://example.com\")[mispelled argument] and catch typoo";
        let ranges = prose_ranges_for(text, false);
        let prose = ranges
            .into_iter()
            .map(|range| &text[range.start_utf8..range.end_utf8])
            .collect::<Vec<_>>()
            .join("");

        assert!(prose.contains("Spell prose"));
        assert!(prose.contains("link"));
        assert!(prose.contains("mispelled argument"));
        assert!(prose.contains("and catch typoo"));
    }

    #[test]
    fn compiles_typst_to_svg_pdf_and_html() {
        let root = test_workspace("render");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("main.typ"), "= Hello\nRendered from embedded Typst.").unwrap();
        let package_path = root.join("packages-local");
        let package_cache_path = root.join("packages-cache");
        fs::create_dir_all(&package_path).unwrap();
        fs::create_dir_all(&package_cache_path).unwrap();

        let root_c = CString::new(root.to_string_lossy().as_bytes()).unwrap();
        let main_c = CString::new("main.typ").unwrap();
        let package_c = CString::new(package_path.to_string_lossy().as_bytes()).unwrap();
        let cache_c = CString::new(package_cache_path.to_string_lossy().as_bytes()).unwrap();

        let svg = compile_svg_response(
            root_c.as_ptr(),
            main_c.as_ptr(),
            package_c.as_ptr(),
            cache_c.as_ptr(),
        )
        .unwrap();
        assert!(svg.ok);
        assert!(!svg.pages.is_empty());
        assert!(svg.pages[0].contains("<svg"));
        assert!(svg.source_rects.iter().any(|rect| {
            rect.file == "main.typ" && rect.start_utf8 <= 2 && rect.end_utf8 >= 2
        }));

        let pdf = compile_pdf_response(
            root_c.as_ptr(),
            main_c.as_ptr(),
            package_c.as_ptr(),
            cache_c.as_ptr(),
        )
        .unwrap();
        assert!(pdf.ok);
        assert!(pdf.source_rects.iter().any(|rect| {
            rect.file == "main.typ" && rect.start_utf8 <= 2 && rect.end_utf8 >= 2
        }));
        assert!(pdf.pdf_base64.unwrap().len() > 100);

        let html = compile_html_response(
            root_c.as_ptr(),
            main_c.as_ptr(),
            package_c.as_ptr(),
            cache_c.as_ptr(),
        )
        .unwrap();
        assert!(html.ok);
        let html_output = html.html.unwrap();
        assert!(html_output.contains("<html"));
        assert!(html_output.contains("Hello"));

        let _ = fs::remove_dir_all(root);
    }

    fn test_workspace(name: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("typeset-{name}-{}-{nanos}", std::process::id()))
    }
}
