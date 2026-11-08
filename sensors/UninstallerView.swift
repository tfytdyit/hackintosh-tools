import SwiftUI
import AppKit

struct UninstallerView: View {
    @StateObject private var u = Uninstaller()
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var alsoLeftovers = true
    @State private var confirm = false
    @State private var hint = ""

    private var shown: [AppItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return u.apps }
        return u.apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }
    private var selectedApps: [AppItem] { u.apps.filter { selected.contains($0.id) } }
    private var selectedSize: Int64 { selectedApps.reduce(0) { $0 + $1.size } }

    var body: some View {
        WindowShell(title: "卸载程序", icon: "trash.slash.fill", tint: .orange,
                    subtitle: "\(u.apps.count) 个应用 · 已选 \(selected.count) 项") {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        TextField("搜索程序或 bundle id", text: $query)
                            .textFieldStyle(.plain).font(.system(size: 11.5))
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

                    if u.scanning { ProgressView().controlSize(.small) }
                    PillButton(title: "重新扫描", icon: "arrow.clockwise") { u.scan() }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(shown) { app in
                            appRow(app)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }

                Divider().opacity(0.5)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("同时清理该程序在「个人」目录下的残留（缓存 / 偏好设置 / 容器）", isOn: $alsoLeftovers)
                        .font(.system(size: 10.5))
                        .toggleStyle(.switch).controlSize(.mini)
                    HStack(spacing: 10) {
                        Text(selected.isEmpty ? "未选择任何应用" : "已选 \(selected.count) 项 · \(Toolbox.human(selectedSize))")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        if alsoLeftovers && !selected.isEmpty {
                            let extra = selectedApps.reduce(Int64(0)) { $0 + u.leftoversSize(for: $1) }
                            Text("+ 残留 \(Toolbox.human(extra))")
                                .font(.system(size: 10.5)).foregroundStyle(.orange)
                        }
                        Spacer()
                        PillButton(title: "移到废纸篓", icon: "trash", tint: .red, filled: !selected.isEmpty) {
                            confirm = true
                        }
                        .disabled(selected.isEmpty)
                        .opacity(selected.isEmpty ? 0.45 : 1)
                    }
                    if !hint.isEmpty || !u.message.isEmpty {
                        Text(hint.isEmpty ? u.message : hint)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 540, height: 500)
        .onAppear { if u.apps.isEmpty { u.scan() } }
        .alert("确认卸载 \(selected.count) 个程序？", isPresented: $confirm) {
            Button("移到废纸篓", role: .destructive) {
                u.uninstall(selectedApps, removeLeftovers: alsoLeftovers) { msg in
                    hint = msg
                    selected.removeAll()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会移到废纸篓（可恢复），不会直接删除。" + (alsoLeftovers ? "同时处理残留文件。" : ""))
        }
    }

    @ViewBuilder
    private func appRow(_ app: AppItem) -> some View {
        let isSel = selected.contains(app.id)
        Button {
            if isSel { selected.remove(app.id) } else { selected.insert(app.id) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSel ? Color.accentColor : Color.secondary.opacity(0.5))
                Group {
                    if let ic = app.icon {
                        Image(nsImage: ic).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Text(app.bundleID.isEmpty ? "—" : app.bundleID)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(Toolbox.human(app.size))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSel ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSel ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 0.6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
