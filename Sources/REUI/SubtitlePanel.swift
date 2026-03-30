import SwiftUI
import CoreMedia
import RECore
import REAudioAnalysis

/// Панель управления субтитрами и стилями
struct SubtitlePanel: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Субтитры")
                .font(.headline)

            // Model selection
            modelSelectionSection

            // Транскрибация
            if viewModel.isTranscribing {
                VStack(spacing: 4) {
                    ProgressView(value: viewModel.transcriptionProgress)
                    Text(viewModel.transcriptionPhase)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !viewModel.transcriptionDetail.isEmpty {
                        Text(viewModel.transcriptionDetail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            } else {
                Button {
                    viewModel.transcribe()
                } label: {
                    Label("Транскрибировать", systemImage: "text.word.spacing")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.project.sourceURL == nil)

                // Model state indicator
                modelStateIndicator
            }

            if !viewModel.subtitleEntries.isEmpty {
                Divider()

                // === LIVE PREVIEW (macOS only — on iOS the real preview is visible above) ===
                #if os(macOS)
                subtitlePreview
                Divider()
                #endif

                // Стиль
                HStack {
                    Text("Стиль:")
                    Picker("", selection: Binding(
                        get: { viewModel.subtitleStyle.preset },
                        set: { viewModel.subtitleStyle = SubtitleStyle.forPreset($0) }
                    )) {
                        ForEach(SubtitlePreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Показать/скрыть
                Toggle("Показать субтитры", isOn: $viewModel.showSubtitles)
                    .font(.caption)

                // Позиция
                HStack {
                    Text("Позиция")
                    Spacer()
                    Button("Верх") {
                        viewModel.subtitleStyle.position = .top
                        viewModel.subtitleStyle.customYCenter = SubtitlePosition.top.yCenter
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Центр") {
                        viewModel.subtitleStyle.position = .center
                        viewModel.subtitleStyle.customYCenter = SubtitlePosition.center.yCenter
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Низ") {
                        viewModel.subtitleStyle.position = .bottom
                        viewModel.subtitleStyle.customYCenter = SubtitlePosition.bottom.yCenter
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Точная Y позиция
                HStack {
                    Text("Y")
                    Slider(
                        value: Binding(
                            get: { viewModel.subtitleStyle.effectiveYCenter },
                            set: { viewModel.subtitleStyle.customYCenter = $0 }
                        ),
                        in: 200...1700,
                        step: 10
                    )
                    Text("\(Int(viewModel.subtitleStyle.effectiveYCenter))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 40)
                }

                // Безопасные зоны
                Toggle("Показать безопасные зоны", isOn: $viewModel.showSafeZones)
                    .font(.caption)

                // Размер шрифта
                HStack {
                    Text("Размер")
                    Slider(value: $viewModel.subtitleStyle.fontSize, in: 32...72, step: 2)
                    Text("\(Int(viewModel.subtitleStyle.fontSize))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 30)
                }

                // Заглавные
                Toggle("ЗАГЛАВНЫЕ", isOn: $viewModel.subtitleStyle.isUppercase)
                    .font(.caption)

                Divider()

                // === ЦВЕТ КАРАОКЕ ===
                VStack(alignment: .leading, spacing: 6) {
                    Text("Цвет караоке")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Горизонтальный ряд цветных кружков
                    HStack(spacing: 8) {
                        ForEach(Array(CodableColor.highlightPresets.enumerated()), id: \.offset) { _, preset in
                            Circle()
                                .fill(Color(red: preset.color.red, green: preset.color.green, blue: preset.color.blue))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .stroke(
                                            isHighlightSelected(preset.color) ? Color.white : Color.clear,
                                            lineWidth: 2
                                        )
                                )
                                .shadow(color: isHighlightSelected(preset.color) ? .white.opacity(0.5) : .clear, radius: 3)
                                .onTapGesture {
                                    viewModel.subtitleStyle.highlightColor = preset.color
                                }
                        }
                    }
                }

                Divider()

                // === ФОН СУБТИТРОВ ===
                VStack(alignment: .leading, spacing: 6) {
                    Text("Фон субтитров")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Форма фона
                    HStack {
                        Text("Форма")
                            .font(.caption)
                        Picker("", selection: $viewModel.subtitleStyle.backgroundShape) {
                            Text("Прямоугольник").tag(SubtitleBackgroundShape.rectangle)
                            Text("Овал").tag(SubtitleBackgroundShape.oval)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    // Прозрачность
                    HStack {
                        Text("Затемнение")
                            .font(.caption)
                        Slider(value: $viewModel.subtitleStyle.backgroundOpacity, in: 0...1, step: 0.05)
                        Text("\(Int(viewModel.subtitleStyle.backgroundOpacity * 100))%")
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 35)
                    }

                    // Горизонтальный отступ
                    HStack {
                        Text("Ширина")
                            .font(.caption)
                        Slider(value: $viewModel.subtitleStyle.backgroundPaddingH, in: 0...80, step: 4)
                        Text("\(Int(viewModel.subtitleStyle.backgroundPaddingH))")
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 25)
                    }

                    // Вертикальный отступ
                    HStack {
                        Text("Высота")
                            .font(.caption)
                        Slider(value: $viewModel.subtitleStyle.backgroundPaddingV, in: 0...60, step: 4)
                        Text("\(Int(viewModel.subtitleStyle.backgroundPaddingV))")
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 25)
                    }

                    // Размытие
                    HStack {
                        Text("Размытие")
                            .font(.caption)
                        Slider(value: $viewModel.subtitleStyle.backgroundBlurRadius, in: 0...40, step: 2)
                        Text("\(Int(viewModel.subtitleStyle.backgroundBlurRadius))")
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 25)
                    }
                }

                Divider()

                // Список субтитров
                Text("\(viewModel.subtitleEntries.count) сегментов")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(viewModel.subtitleEntries.enumerated()), id: \.element.id) { index, entry in
                            subtitleRow(entry, index: index)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding()
    }

    // MARK: - Live Preview

    private var subtitlePreview: some View {
        // Миниатюрный 9:16 превью с субтитрами
        ZStack {
            // Тёмный фон имитирующий видео
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.15))

            GeometryReader { geo in
                let previewSize = geo.size
                let scale = min(previewSize.width / 1080, previewSize.height / 1920)
                let fontSize = viewModel.subtitleStyle.fontSize * scale
                let yPos = viewModel.subtitleStyle.effectiveYCenter * scale
                let hasBackground = viewModel.subtitleStyle.backgroundOpacity > 0.01
                let blur = viewModel.subtitleStyle.backgroundBlurRadius * scale

                // Пример субтитров
                let sampleText = buildPreviewAttributedString(fontSize: fontSize)

                Text(sampleText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4 * scale)
                    .frame(maxWidth: previewSize.width * 0.85)
                    .padding(.horizontal, hasBackground ? 12 * scale : 0)
                    .padding(.vertical, hasBackground ? 6 * scale : 0)
                    .background(
                        hasBackground ?
                            AnyView(
                                Group {
                                    if blur > 1 {
                                        RoundedRectangle(cornerRadius: 8 * scale)
                                            .fill(Color(
                                                red: viewModel.subtitleStyle.backgroundColor.red,
                                                green: viewModel.subtitleStyle.backgroundColor.green,
                                                blue: viewModel.subtitleStyle.backgroundColor.blue,
                                                opacity: viewModel.subtitleStyle.backgroundOpacity
                                            ))
                                            .blur(radius: blur)
                                    } else {
                                        RoundedRectangle(cornerRadius: 8 * scale)
                                            .fill(Color(
                                                red: viewModel.subtitleStyle.backgroundColor.red,
                                                green: viewModel.subtitleStyle.backgroundColor.green,
                                                blue: viewModel.subtitleStyle.backgroundColor.blue,
                                                opacity: viewModel.subtitleStyle.backgroundOpacity
                                            ))
                                    }
                                }
                            )
                            : AnyView(EmptyView())
                    )
                    .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                    .position(x: previewSize.width / 2, y: yPos)
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .frame(maxHeight: 180)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func buildPreviewAttributedString(fontSize: CGFloat) -> AttributedString {
        let style = viewModel.subtitleStyle
        let textColor = Color(red: style.textColor.red, green: style.textColor.green, blue: style.textColor.blue, opacity: style.textColor.alpha)
        let highlightColor = Color(red: style.highlightColor.red, green: style.highlightColor.green, blue: style.highlightColor.blue, opacity: style.highlightColor.alpha)
        let font = Font.custom(style.fontName, size: fontSize)

        let words = ["Пример", "текста", "субтитров"]
        var result = AttributedString()

        for (idx, word) in words.enumerated() {
            let isActive = idx == 1 // highlight middle word
            let displayWord = style.isUppercase ? word.uppercased() : word
            let text = idx > 0 ? " \(displayWord)" : displayWord

            var attr = AttributedString(text)
            attr.font = font
            attr.foregroundColor = isActive ? highlightColor : textColor
            result.append(attr)
        }

        return result
    }

    // MARK: - Helpers

    private func isHighlightSelected(_ color: CodableColor) -> Bool {
        let c = viewModel.subtitleStyle.highlightColor
        return abs(c.red - color.red) < 0.05 &&
               abs(c.green - color.green) < 0.05 &&
               abs(c.blue - color.blue) < 0.05
    }

    private func subtitleRow(_ entry: SubtitleEntry, index: Int) -> some View {
        HStack(spacing: 6) {
            Text(formatTime(entry.startTime))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 55, alignment: .trailing)

            TextField("", text: Binding(
                get: { viewModel.subtitleEntries[safe: index]?.text ?? "" },
                set: { newText in
                    if index < viewModel.subtitleEntries.count {
                        viewModel.subtitleEntries[index].text = newText
                        viewModel.updateSubtitleWords(at: index)
                    }
                }
            ))
            .font(.caption)
            .textFieldStyle(.plain)
            .frame(maxWidth: .infinity)

            Button {
                if let tlTime = viewModel.timeline.timelineTime(forSourceTime: entry.startTime) {
                    viewModel.seekSmoothly(to: tlTime)
                }
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.plain)
            .font(.caption)

            Button {
                if index < viewModel.subtitleEntries.count {
                    viewModel.subtitleEntries.remove(at: index)
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.6))
            }
            .buttonStyle(.plain)
            .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
    }

    private func formatTime(_ time: CMTime) -> String {
        let secs = CMTimeGetSeconds(time)
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        let ms = Int((secs - Double(Int(secs))) * 10)
        return String(format: "%d:%02d.%d", m, s, ms)
    }

    // MARK: - Model Selection

    private var modelSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Language picker
            HStack {
                Text("Язык:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: { viewModel.modelManager.selectedLanguage },
                    set: { viewModel.modelManager.selectedLanguage = $0 }
                )) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                    Text("Авто").tag("auto")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            // Model list with download/delete
            VStack(spacing: 4) {
                ForEach(viewModel.modelManager.modelCatalog) { model in
                    modelRow(model)
                }
            }

            // Cache info + clear button
            HStack {
                let size = viewModel.modelManager.cacheSize()
                Text("Кеш: \(ModelManager.formatBytes(size))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Очистить кеш") {
                    viewModel.modelManager.clearCache()
                }
                .font(.caption2)
                .foregroundColor(.red.opacity(0.8))
            }
            .padding(.top, 4)
        }
    }

    private func modelRow(_ model: ASRModelInfo) -> some View {
        let isSelected = viewModel.modelManager.selectedModelId == model.variant
        let downloadState = viewModel.modelManager.downloadState(for: model.variant)

        return HStack(spacing: 8) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.body)

            // Model info
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                HStack(spacing: 4) {
                    Text(formatSize(model.approxSizeMB))
                    Text("·")
                    Text(model.speedNote)
                    // Quality stars
                    Text("·")
                    HStack(spacing: 1) {
                        ForEach(0..<model.qualityStars, id: \.self) { _ in
                            Image(systemName: "star.fill")
                        }
                    }
                    .font(.system(size: 7))
                    .foregroundColor(.yellow)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Status / Action button
            modelActionButton(model: model, state: downloadState)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Select this model (downloads on transcribe if needed)
            viewModel.modelManager.selectedModelId = model.variant
        }
    }

    @ViewBuilder
    private func modelActionButton(model: ASRModelInfo, state: ModelDownloadState) -> some View {
        switch state {
        case .notDownloaded:
            Button {
                viewModel.modelManager.downloadModelInBackground(variant: model.variant)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

        case .downloading(let progress, let detail):
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: progress)
                    .frame(width: 60)
                Text(detail ?? String(format: "%.0f%%", progress * 100))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

        case .downloaded:
            Button {
                viewModel.modelManager.deleteModel(variant: model.variant)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)

        case .loadedInMemory:
            HStack(spacing: 3) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text("В памяти")
                    .font(.caption2)
                    .foregroundColor(.green)
            }
        }
    }

    private var modelStateIndicator: some View {
        Group {
            switch viewModel.modelManager.state {
            case .idle:
                EmptyView()
            case .downloading(let progress, let detail):
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 100)
                    Text(detail ?? String(format: "%.0f%%", progress * 100))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            case .loading:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Загрузка модели...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            case .ready:
                EmptyView()  // State shown inline in model list
            case .error(let msg):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text(msg)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func formatSize(_ mb: Int) -> String {
        if mb >= 1000 {
            return String(format: "%.1f ГБ", Double(mb) / 1000)
        }
        return "\(mb) МБ"
    }
}
