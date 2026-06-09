// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct SourceRange: Equatable, Sendable {
    public var path: String
    public var start: Int
    public var end: Int

    public init(path: String, start: Int, end: Int) {
        self.path = path
        self.start = start
        self.end = end
    }
}

public struct PreviewSourceRect: Equatable, Sendable {
    public var page: Int
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var range: SourceRange

    public init(page: Int, x: Double, y: Double, width: Double, height: Double, range: SourceRange) {
        self.page = page
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.range = range
    }
}

public struct HTMLPreview: Equatable, Sendable {
    public var html: String
    public var ranges: [String: SourceRange]
    public var sourceRects: [PreviewSourceRect]

    public init(html: String, ranges: [String: SourceRange], sourceRects: [PreviewSourceRect] = []) {
        self.html = html
        self.ranges = ranges
        self.sourceRects = sourceRects
    }
}

public struct PreviewHTMLBuilder: Sendable {
    public init() {}

    public func build(svgPages: [String]) -> HTMLPreview {
        build(svgPages: svgPages, sourcePath: nil, sourceText: nil, sourceRects: [])
    }

    public func build(svgPages: [String], sourcePath: String, sourceText: String) -> HTMLPreview {
        build(svgPages: svgPages, sourcePath: Optional(sourcePath), sourceText: Optional(sourceText), sourceRects: [])
    }

    public func build(svgPages: [String], sourcePath: String, sourceText: String, sourceRects: [PreviewSourceRect]) -> HTMLPreview {
        build(svgPages: svgPages, sourcePath: Optional(sourcePath), sourceText: Optional(sourceText), sourceRects: sourceRects)
    }

    public func build(svgPages: [String], sourceRects: [PreviewSourceRect]) -> HTMLPreview {
        build(svgPages: svgPages, sourcePath: nil, sourceText: nil, sourceRects: sourceRects)
    }

    public func buildQuickLook(compiledHTML: String) -> HTMLPreview {
        HTMLPreview(html: Self.injectQuickLookStyles(into: compiledHTML), ranges: [:])
    }

    private func build(svgPages: [String], sourcePath: String?, sourceText: String?, sourceRects: [PreviewSourceRect]) -> HTMLPreview {
        let sourceMap = sourcePath.flatMap { path in
            sourceText.map { Self.sourceLineRanges(path: path, text: $0) }
        } ?? (ranges: [:], tokens: [])
        let previewDataJSON = Self.previewDataJSON(
            ranges: sourceMap.ranges,
            sourceTokens: sourceMap.tokens,
            sourceRects: sourceRects
        )
        let pages = svgPages.enumerated().map { index, svg in
            """
            <section class="page" data-page-index="\(index)" aria-label="Page \(index + 1)">
              \(svg)
            </section>
            """
        }

        let html = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=0.25, maximum-scale=5, user-scalable=yes">
          <style>
            :root { color-scheme: light dark; }
            html, body {
              margin: 0;
              min-height: 100%;
              background: color-mix(in srgb, Canvas 88%, CanvasText 12%);
            }
            body {
              padding: 0;
              box-sizing: border-box;
            }
            main {
              display: grid;
              justify-items: center;
              gap: 12px;
            }
            .page {
              width: 100%;
              background: white;
              box-shadow: 0 10px 34px rgba(0,0,0,.18);
              contain: layout paint style;
              content-visibility: auto;
              contain-intrinsic-size: 1000px 1414px;
              overflow: hidden;
            }
            .preview-page-placeholder {
              aspect-ratio: 1 / 1.4142135624;
            }
            .page svg {
              display: block;
              width: 100%;
              height: auto;
            }
            .page svg [data-source] {
              cursor: pointer;
            }
            .page svg [data-source].active {
              opacity: .82;
            }
          </style>
        </head>
        <body>
          <main>
            \(pages.joined(separator: "\n"))
          </main>
          <script id="typeset-preview-data" type="application/json">\(Self.scriptJSON(previewDataJSON))</script>
          <script>
            \(Self.previewRuntimeScript())
          </script>
        </body>
        </html>
        """

        return HTMLPreview(html: html, ranges: sourceMap.ranges, sourceRects: sourceRects)
    }

    public func build(package: DocumentPackage) -> HTMLPreview {
        let path = package.mainTypstPath ?? package.selectedPath
        let source = package.text(for: path)
        var ranges: [String: SourceRange] = [:]
        var blocks: [String] = []
        var offset = 0

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let token = "s\(ranges.count)"
            let end = offset + (line as NSString).length
            ranges[token] = SourceRange(path: path, start: offset, end: end)

            if trimmed.hasPrefix("=") {
                let level = max(1, min(3, trimmed.prefix { $0 == "=" }.count))
                let text = trimmed.drop { $0 == "=" }.trimmingCharacters(in: .whitespaces)
                blocks.append("<h\(level) data-source='\(token)'>\(Self.escape(text))</h\(level)>")
            } else if trimmed.hasPrefix("#image(") {
                blocks.append("<figure data-source='\(token)'><div class='asset'>image asset</div><figcaption>\(Self.escape(trimmed))</figcaption></figure>")
            } else if trimmed.isEmpty {
                blocks.append("<div class='blank' data-source='\(token)'></div>")
            } else {
                blocks.append("<p data-source='\(token)'>\(Self.inlineMarkup(trimmed))</p>")
            }

            offset = end + 1
        }

        let previewDataJSON = Self.previewDataJSON(ranges: ranges, sourceTokens: [], sourceRects: [])
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=0.25, maximum-scale=5, user-scalable=yes">
          <style>
            :root { color-scheme: light dark; }
            body {
              margin: 0;
              padding: 8px;
              font: 16px/1.55 -apple-system, BlinkMacSystemFont, "New York", serif;
              background: Canvas;
              color: CanvasText;
            }
            main {
              max-width: 760px;
              min-height: calc(100vh - 16px);
              margin: 0 auto;
              padding: 18px 22px;
              background: color-mix(in srgb, Canvas 96%, CanvasText 4%);
              box-shadow: 0 18px 60px rgba(0,0,0,.12);
              border: 1px solid color-mix(in srgb, CanvasText 12%, transparent);
            }
            h1, h2, h3 { line-height: 1.15; margin: 1.5em 0 .45em; }
            h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
            p { margin: .7em 0; }
            code {
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
              font-size: .9em;
              padding: .1em .3em;
              border-radius: 4px;
              background: color-mix(in srgb, CanvasText 9%, transparent);
            }
            [data-source] {
              cursor: pointer;
              border-radius: 5px;
              transition: background .12s ease;
            }
            [data-source]:hover, [data-source].active {
              background: color-mix(in srgb, Highlight 18%, transparent);
            }
            .blank { height: 1em; }
            .asset {
              display: grid;
              place-items: center;
              min-height: 160px;
              border: 1px dashed color-mix(in srgb, CanvasText 30%, transparent);
              border-radius: 6px;
              font: 13px -apple-system, BlinkMacSystemFont, sans-serif;
              color: color-mix(in srgb, CanvasText 60%, transparent);
            }
          </style>
        </head>
        <body>
          <main>\(blocks.joined(separator: "\n"))</main>
          <script id="typeset-preview-data" type="application/json">\(Self.scriptJSON(previewDataJSON))</script>
          <script>
            \(Self.previewRuntimeScript())
          </script>
        </body>
        </html>
        """

        return HTMLPreview(html: html, ranges: ranges)
    }

    private static func inlineMarkup(_ text: String) -> String {
        var escaped = escape(text)
        escaped = escaped.replacingOccurrences(of: "`", with: "")
        return escaped
    }

    private static func injectQuickLookStyles(into html: String) -> String {
        let style = """
        <style id="typeset-quicklook-style">
          :root {
            color-scheme: light dark;
            --typeset-paper: #fffdf8;
            --typeset-ink: #181511;
            --typeset-muted: #6d6257;
            --typeset-link: #1f5fbf;
            --typeset-rule: color-mix(in srgb, CanvasText 18%, transparent);
          }
          html {
            min-height: 100%;
            background:
              linear-gradient(180deg, rgba(255,255,255,.52), rgba(255,255,255,0) 220px),
              #ede7dc;
          }
          body {
            box-sizing: border-box;
            min-height: 100vh;
            margin: 0;
            padding: clamp(24px, 5vw, 64px);
            color: var(--typeset-ink);
            background: transparent;
            font-family: "Linux Libertine", "Libertinus Serif", "New York", Georgia, serif;
            font-size: clamp(18px, 1.72vw, 24px);
            line-height: 1.55;
            text-rendering: optimizeLegibility;
            -webkit-font-smoothing: antialiased;
          }
          body > :not(script):not(style) {
            max-width: 780px;
            margin-left: auto;
            margin-right: auto;
          }
          h1, h2, h3, h4, h5, h6 {
            color: var(--typeset-ink);
            font-weight: 700;
            line-height: 1.08;
            margin: 1.35em auto .45em;
          }
          h1 { font-size: 2.1em; }
          h2 { font-size: 1.55em; }
          h3 { font-size: 1.25em; }
          p, ul, ol, blockquote, figure, table, pre {
            margin-top: .85em;
            margin-bottom: .85em;
          }
          a {
            color: var(--typeset-link);
            text-decoration-thickness: .06em;
            text-underline-offset: .13em;
          }
          blockquote {
            padding: .05em 0 .05em 1.1em;
            border-left: 3px solid var(--typeset-rule);
            color: var(--typeset-muted);
          }
          img, svg, video, canvas {
            max-width: 100%;
            height: auto;
          }
          table {
            width: 100%;
            border-collapse: collapse;
            font-size: .94em;
          }
          th, td {
            padding: .35em .5em;
            border-bottom: 1px solid var(--typeset-rule);
            vertical-align: top;
          }
          code, kbd, samp, pre {
            font-family: "Fira Code", ui-monospace, SFMono-Regular, Menlo, monospace;
          }
          code, kbd, samp {
            border-radius: 4px;
            padding: .07em .24em;
            background: color-mix(in srgb, CanvasText 8%, transparent);
            font-size: .84em;
          }
          pre {
            overflow: auto;
            border-radius: 8px;
            padding: .85em 1em;
            background: color-mix(in srgb, CanvasText 7%, transparent);
            font-size: .82em;
            line-height: 1.45;
          }
          math {
            font-family: "Linux Libertine", "Libertinus Serif", "STIX Two Math", serif;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --typeset-paper: #171410;
              --typeset-ink: #f4efe7;
              --typeset-muted: #beb2a5;
              --typeset-link: #8eb8ff;
            }
            html {
              background:
                linear-gradient(180deg, rgba(255,255,255,.05), rgba(255,255,255,0) 220px),
                #11100e;
            }
          }
        </style>
        """

        if let headEnd = html.range(of: "</head>", options: [.caseInsensitive, .backwards]) {
            var result = html
            result.insert(contentsOf: "\n\(style)\n", at: headEnd.lowerBound)
            return result
        }

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          \(style)
        </head>
        <body>
          \(html)
        </body>
        </html>
        """
    }

    private static func previewDataJSON(
        ranges: [String: SourceRange],
        sourceTokens: [String],
        sourceRects: [PreviewSourceRect]
    ) -> String {
        let rangePayload = ranges.mapValues { range in
            ["path": range.path, "start": range.start, "end": range.end] as [String: Any]
        }
        let rectPayload = sourceRects.map { rect in
            [
                "page": rect.page,
                "x": rect.x,
                "y": rect.y,
                "width": rect.width,
                "height": rect.height,
                "path": rect.range.path,
                "start": rect.range.start,
                "end": rect.range.end,
            ] as [String: Any]
        }
        return jsonString(
            [
                "ranges": rangePayload,
                "sourceTokens": sourceTokens,
                "sourceRects": rectPayload,
            ],
            fallback: #"{"ranges":{},"sourceTokens":[],"sourceRects":[]}"#
        )
    }

    private static func scriptJSON(_ json: String) -> String {
        json.replacingOccurrences(of: "</", with: "<\\/")
    }

    private static func previewRuntimeScript() -> String {
        """
        (() => {
          function previewData() {
            const node = document.getElementById('typeset-preview-data');
            if (!node) return { ranges: {}, sourceTokens: [], sourceRects: [] };
            try {
              const data = JSON.parse(node.textContent || '{}');
              return {
                ranges: data.ranges || {},
                sourceTokens: data.sourceTokens || [],
                sourceRects: data.sourceRects || []
              };
            } catch {
              return { ranges: {}, sourceTokens: [], sourceRects: [] };
            }
          }

          function isVisualPreviewElement(element) {
            const tag = element.tagName.toLowerCase();
            if (!['g', 'path', 'image', 'rect', 'circle', 'ellipse', 'line', 'polyline', 'polygon', 'text', 'foreignobject'].includes(tag)) {
              return false;
            }
            if (tag === 'path') {
              const fill = (element.getAttribute('fill') || '').toLowerCase();
              const stroke = (element.getAttribute('stroke') || '').toLowerCase();
              if ((fill === '#ffffff' || fill === '#fff' || fill === 'white') && (!stroke || stroke === 'none')) {
                return false;
              }
            }
            return true;
          }

          function previewElements() {
            const elements = [];
            document.querySelectorAll('.page svg').forEach(svg => {
              Array.from(svg.children).forEach(child => {
                if (isVisualPreviewElement(child)) {
                  elements.push(child);
                }
              });
            });
            return elements;
          }

          function annotatePreviewSources() {
            const sourceTokens = previewData().sourceTokens;
            if (!sourceTokens.length) return;
            const elements = previewElements();
            if (!elements.length) return;

            elements.forEach((element, index) => {
              const tokenIndex = elements.length <= sourceTokens.length
                ? index
                : Math.floor(((index + 0.5) * sourceTokens.length) / elements.length);
              element.dataset.source = sourceTokens[Math.min(sourceTokens.length - 1, tokenIndex)];
            });
          }

          function nearestSourceElement(event) {
            const page = event.target.closest('.page');
            if (!page) return null;
            const elements = Array.from(page.querySelectorAll('[data-source]'));
            let best = null;
            let bestDistance = Number.POSITIVE_INFINITY;
            elements.forEach(element => {
              const rect = element.getBoundingClientRect();
              if (!rect.width && !rect.height) return;
              const centerY = rect.top + rect.height / 2;
              const dy = event.clientY - centerY;
              const dx = event.clientX < rect.left ? rect.left - event.clientX : event.clientX > rect.right ? event.clientX - rect.right : 0;
              const distance = Math.abs(dy) + dx * 0.25;
              if (distance < bestDistance) {
                best = element;
                bestDistance = distance;
              }
            });
            return best;
          }

          function rangeForPreviewPoint(event) {
            const page = event.target.closest('.page');
            const svg = page?.querySelector('svg');
            if (!page || !svg) return null;

            const pageIndex = Number(page.dataset.pageIndex || '0');
            const rects = previewData().sourceRects.filter(rect => Number(rect.page) === pageIndex);
            if (!rects.length) return null;

            const bounds = svg.getBoundingClientRect();
            const viewBox = svg.viewBox?.baseVal;
            if (!bounds.width || !bounds.height || !viewBox?.width || !viewBox?.height) return null;

            const x = viewBox.x + (event.clientX - bounds.left) * (viewBox.width / bounds.width);
            const y = viewBox.y + (event.clientY - bounds.top) * (viewBox.height / bounds.height);
            let best = null;
            let bestScore = Number.POSITIVE_INFINITY;

            rects.forEach(rect => {
              const left = Number(rect.x);
              const top = Number(rect.y);
              const width = Number(rect.width);
              const height = Number(rect.height);
              if (!Number.isFinite(left + top + width + height) || width <= 0 || height <= 0) return;

              const contains = x >= left - 1 && x <= left + width + 1 && y >= top - 1 && y <= top + height + 1;
              const dx = x < left ? left - x : x > left + width ? x - (left + width) : 0;
              const dy = y < top ? top - y : y > top + height ? y - (top + height) : 0;
              const distance = Math.abs(dy) + Math.abs(dx) * 0.25;
              const score = contains ? width * height : 1000000 + distance;
              if (score < bestScore) {
                best = rect;
                bestScore = score;
              }
            });

            if (!best || bestScore >= 1000000 + 18) return null;
            return {
              path: best.path,
              start: best.start,
              end: best.end
            };
          }

          function seekRange(range, element) {
            if (!range || !window.webkit?.messageHandlers?.sourceSeek) return;
            document.querySelectorAll('.active').forEach(node => node.classList.remove('active'));
            element?.classList.add('active');
            window.webkit.messageHandlers.sourceSeek.postMessage(range);
          }

          function seekSource(token, element) {
            seekRange(previewData().ranges[token], element);
          }

          function capturePreviewAnchor() {
            const scrollY = window.scrollY;
            const maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
            const anchor = {
              x: window.scrollX,
              y: scrollY,
              ratio: maxY > 0 ? Math.max(0, Math.min(1, scrollY / maxY)) : 0,
              pageIndex: -1,
              pageOffset: scrollY,
              pageOffsetRatio: 0
            };
            const pages = Array.from(document.querySelectorAll('.page'));
            pages.forEach((page, index) => {
              const rect = page.getBoundingClientRect();
              const top = rect.top + scrollY;
              if (top <= scrollY + 1) {
                anchor.pageIndex = index;
                anchor.pageOffset = Math.max(0, scrollY - top);
                anchor.pageOffsetRatio = rect.height > 0 ? Math.max(0, Math.min(1, anchor.pageOffset / rect.height)) : 0;
              }
            });
            return anchor;
          }

          function restorePreviewAnchor(anchor) {
            const restore = () => {
              const maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
              let y = Number.isFinite(anchor?.y) ? anchor.y : maxY * (anchor?.ratio || 0);
              const pages = Array.from(document.querySelectorAll('.page'));
              if (anchor?.pageIndex >= 0 && anchor.pageIndex < pages.length) {
                const rect = pages[anchor.pageIndex].getBoundingClientRect();
                const top = rect.top + window.scrollY;
                y = top + Math.min(anchor.pageOffset || 0, rect.height * (anchor.pageOffsetRatio || 0));
              }
              if (!Number.isFinite(y)) {
                y = maxY * (anchor?.ratio || 0);
              }
              window.scrollTo(Number.isFinite(anchor?.x) ? anchor.x : 0, Math.max(0, Math.min(maxY, y)));
            };
            restore();
            requestAnimationFrame(restore);
          }

          function replacementPagesFrom(nextMain) {
            if (typeof nextMain === 'string') {
              const template = document.createElement('template');
              template.innerHTML = nextMain;
              return Array.from(template.content.children);
            }
            if (!nextMain?.children) return [];
            return Array.from(nextMain.children).map(page => document.importNode(page, true));
          }

          function replacementPageOrder(count, preferredIndex) {
            const order = [];
            const center = preferredIndex >= 0 && preferredIndex < count ? preferredIndex : 0;
            for (let distance = 0; distance < count; distance += 1) {
              const before = center - distance;
              const after = center + distance;
              if (before >= 0) order.push(before);
              if (after < count && after !== before) order.push(after);
            }
            return order;
          }

          function placeholderForPage(page, index) {
            const placeholder = document.createElement('section');
            placeholder.className = 'page preview-page-placeholder';
            placeholder.dataset.pageIndex = String(index);
            placeholder.setAttribute('aria-label', `Page ${index + 1}`);
            const svg = page.querySelector('svg');
            const viewBox = (svg?.getAttribute('viewBox') || '').trim().split(/\\s+/).map(Number);
            if (viewBox.length === 4 && viewBox[2] > 0 && viewBox[3] > 0) {
              placeholder.style.aspectRatio = `${viewBox[2]} / ${viewBox[3]}`;
            }
            return placeholder;
          }

          window.typesetReplacePreview = function(nextMain, dataJSON) {
            const main = document.querySelector('main');
            const dataNode = document.getElementById('typeset-preview-data');
            if (!main || !dataNode) return false;
            const nextPages = replacementPagesFrom(nextMain);
            if (!nextPages.length) return false;

            const anchor = capturePreviewAnchor();
            dataNode.textContent = dataJSON || '{"ranges":{},"sourceTokens":[],"sourceRects":[]}';
            const replacementID = (window.typesetPreviewReplacementID || 0) + 1;
            window.typesetPreviewReplacementID = replacementID;

            const firstPageIndex = anchor.pageIndex >= 0 && anchor.pageIndex < nextPages.length ? anchor.pageIndex : 0;
            const pages = nextPages.map((page, index) => index === firstPageIndex ? page : placeholderForPage(page, index));
            main.replaceChildren(...pages);
            restorePreviewAnchor(anchor);

            const order = replacementPageOrder(nextPages.length, firstPageIndex).filter(index => index !== firstPageIndex);
            const replaceBatch = () => {
              if (window.typesetPreviewReplacementID !== replacementID) return;
              const deadline = performance.now() + 10;
              var replaced = 0;
              while (order.length && (replaced < 2 || performance.now() < deadline)) {
                const index = order.shift();
                const current = main.children[index];
                if (current) {
                  current.replaceWith(nextPages[index]);
                }
                replaced += 1;
              }
              if (order.length) {
                requestAnimationFrame(replaceBatch);
              } else {
                annotatePreviewSources();
                restorePreviewAnchor(anchor);
              }
            };
            requestAnimationFrame(replaceBatch);
            return true;
          };

          annotatePreviewSources();
          document.addEventListener('click', event => {
            const sourceRange = rangeForPreviewPoint(event);
            if (sourceRange) {
              seekRange(sourceRange, event.target.closest('.page'));
              return;
            }
            const element = event.target.closest('[data-source]') || nearestSourceElement(event);
            if (!element) return;
            seekSource(element.dataset.source, element);
          });
        })();
        """
    }

    private static func jsonString(_ value: Any, fallback: String) -> String {
        guard
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value),
            let json = String(data: data, encoding: .utf8)
        else {
            return fallback
        }
        return json
    }

    private struct SourceLine {
        var range: NSRange
        var text: String
        var trimmed: String
    }

    private static func sourceLineRanges(path: String, text: String) -> (ranges: [String: SourceRange], tokens: [String]) {
        let nsText = text as NSString
        let lines = sourceLines(in: nsText)
        var ranges: [String: SourceRange] = [:]
        var tokens: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard !line.trimmed.isEmpty else {
                index += 1
                continue
            }

            let blockEnd = delimitedBlockEnd(in: lines, startingAt: index)
            defer { index = blockEnd + 1 }

            guard isRenderableSourceLine(line.trimmed) else {
                continue
            }

            let token = "s\(tokens.count)"
            let blockRange = sourceRange(from: index, through: blockEnd, in: lines)
            ranges[token] = SourceRange(
                path: path,
                start: blockRange.location,
                end: NSMaxRange(blockRange)
            )
            tokens.append(token)
        }

        if tokens.isEmpty {
            ranges["s0"] = SourceRange(path: path, start: 0, end: min(1, nsText.length))
            tokens.append("s0")
        }

        return (ranges, tokens)
    }

    private static func sourceLines(in nsText: NSString) -> [SourceLine] {
        var lines: [SourceLine] = []
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, _ in
            let text = nsText.substring(with: lineRange)
            lines.append(SourceLine(
                range: lineRange,
                text: text,
                trimmed: text.trimmingCharacters(in: .whitespaces)
            ))
        }
        return lines
    }

    private static func sourceRange(from startIndex: Int, through endIndex: Int, in lines: [SourceLine]) -> NSRange {
        let start = lines[startIndex].range.location
        let end = NSMaxRange(lines[endIndex].range)
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func delimitedBlockEnd(in lines: [SourceLine], startingAt startIndex: Int) -> Int {
        var balance = 0
        var sawOpeningDelimiter = false
        var inString = false
        var inRaw = false

        for index in startIndex..<lines.count {
            let line = lines[index].text
            var previousWasEscape = false

            for character in line {
                if inString {
                    if character == "\"" && !previousWasEscape {
                        inString = false
                    }
                    previousWasEscape = character == "\\" && !previousWasEscape
                    continue
                }

                if inRaw {
                    if character == "`" {
                        inRaw = false
                    }
                    previousWasEscape = false
                    continue
                }

                switch character {
                case "\"":
                    inString = true
                case "`":
                    inRaw = true
                case "(", "[", "{":
                    sawOpeningDelimiter = true
                    balance += 1
                case ")", "]", "}":
                    balance = max(0, balance - 1)
                default:
                    break
                }
                previousWasEscape = false
            }

            if sawOpeningDelimiter && balance == 0 && !inString && !inRaw {
                return index
            }

            if !sawOpeningDelimiter {
                return startIndex
            }
        }

        return startIndex
    }

    private static func isRenderableSourceLine(_ trimmedLine: String) -> Bool {
        guard trimmedLine.hasPrefix("#") else { return true }

        let directivePrefixes = [
            "#import",
            "#set",
            "#show",
            "#let",
        ]
        return !directivePrefixes.contains { prefix in
            trimmedLine == prefix || trimmedLine.hasPrefix(prefix + " ") || trimmedLine.hasPrefix(prefix + "(")
        }
    }

    private static func escape(_ value: some StringProtocol) -> String {
        String(value)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
