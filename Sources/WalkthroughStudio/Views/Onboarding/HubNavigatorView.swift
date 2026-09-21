import SwiftUI

/// The left pane: the recommended order, as a numbered list read from `hub/index.json`.
///
/// It is native rather than part of the web view because it is the window's navigation,
/// not the package's content — and because the coverage strip under it will grow a live
/// fleet summary (M11) that the hub, which only ever sees a finished package, cannot show.
struct HubNavigatorView: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(vm.items) { item in
                    row(item)
                }
                if !vm.items.isEmpty {
                    Text("\(vm.hub.totalMinutes) minutes total")
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                coverage
            }
            .padding(.bottom, 20)
        }
        .background(Brand.cream)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Onboarding")
                .font(.custom("Georgia", size: 20))
                .foregroundStyle(Brand.charcoal)
            Text(vm.hub.repo.display)
                .font(.caption)
                .foregroundStyle(Brand.muted)
                .textSelection(.enabled)
            Text("Recommended order")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.muted)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private func row(_ item: HubIndex.Item) -> some View {
        Button {
            vm.open(anchor: item.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(item.order)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Brand.muted)
                    .frame(width: 18, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.callout)
                        .foregroundStyle(Brand.charcoal)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.kind)
                        .font(.caption2)
                        .foregroundStyle(Brand.muted)
                }
                Spacer(minLength: 6)
                Text("\(item.minutes)m")
                    .font(.caption2)
                    .foregroundStyle(Brand.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent(item) ? Brand.soft : Color.clear)
        }
        .buttonStyle(.plain)
    }

    /// The row matching whatever the stage is showing, whether the hub navigated itself
    /// or the app asked it to.
    private func isCurrent(_ item: HubIndex.Item) -> Bool {
        if case .video(let id) = vm.stage { return item.id == "video:\(id)" }
        guard let anchor = vm.hubAnchor else { return false }
        return anchor == item.id || anchor.hasPrefix(item.id + "#")
    }

    @ViewBuilder
    private var coverage: some View {
        if !vm.hub.coverage.directories.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Coverage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.muted)
                ForEach(vm.hub.coverage.directories) { directory in
                    HStack(spacing: 8) {
                        Text(directory.path)
                            .font(.caption2)
                            .foregroundStyle(Brand.charcoal)
                            .lineLimit(1)
                            .frame(width: 110, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Brand.soft)
                                Capsule().fill(Brand.coral)
                                    .frame(width: geometry.size.width * directory.fraction)
                            }
                        }
                        .frame(height: 6)
                        Text(directory.level)
                            .font(.caption2)
                            .foregroundStyle(Brand.muted)
                            .frame(width: 62, alignment: .trailing)
                            .help(directory.reason ?? "")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }
}
