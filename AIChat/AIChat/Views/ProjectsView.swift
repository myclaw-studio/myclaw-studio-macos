import SwiftUI
import AppKit

struct ProjectsView: View {
    var onBack: () -> Void = {}

    @State private var projects: [ProjectFolder] = []
    @State private var selectedProject: String = "default"
    @State private var files: [ProjectFile] = []
    @State private var isLoadingFiles = false
    @State private var showNewProjectAlert = false
    @State private var newProjectName = ""
    @State private var newProjectDesc = ""

    private let service = BackendService()

    var body: some View {
        VStack(spacing: 0) {
            // 双栏布局
            HStack(spacing: 0) {
                // 左栏：项目列表
                VStack(alignment: .leading, spacing: 0) {
                    List(projects, selection: $selectedProject) { project in
                        HStack(spacing: 6) {
                            Image(systemName: project.name == "default" ? "folder.fill" : "folder")
                                .foregroundStyle(project.name == "default" ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name == "default" ? L.defaultProject : project.name)
                                    .font(.subheadline)
                                Text(L.fileCount(project.fileCount))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                        .tag(project.name)
                    }
                    .listStyle(.sidebar)

                    Divider()

                    Button {
                        newProjectName = ""
                        newProjectDesc = ""
                        showNewProjectAlert = true
                    } label: {
                        Label(L.newProject, systemImage: "plus")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                }
                .frame(width: 180)

                Divider()

                // 右栏：文件列表
                VStack(alignment: .leading, spacing: 0) {
                    if isLoadingFiles {
                        Spacer()
                        ProgressView()
                            .frame(maxWidth: .infinity)
                        Spacer()
                    } else if files.isEmpty {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text(L.noFiles)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        Spacer()
                    } else {
                        List(files) { file in
                            HStack(spacing: 8) {
                                Image(systemName: fileIcon(ext: file.ext))
                                    .foregroundStyle(.blue)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name)
                                        .font(.subheadline)
                                    Text(formatSize(file.size))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(L.openWithDefault)

                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(L.showInFinder)
                            }
                            .padding(.vertical, 2)
                        }
                        .listStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            await loadProjects()
        }
        .onChange(of: selectedProject) { _, newValue in
            Task { await loadFiles(for: newValue) }
        }
        .alert(L.newProject, isPresented: $showNewProjectAlert) {
            TextField(L.projectName, text: $newProjectName)
            TextField(L.projectDesc, text: $newProjectDesc)
            Button(L.cancel, role: .cancel) {}
            Button(L.create) {
                let name = newProjectName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let desc = newProjectDesc.trimmingCharacters(in: .whitespaces)
                Task {
                    try? await service.createProject(name: name, description: desc)
                    await loadProjects()
                    selectedProject = name
                }
            }
        } message: {
            Text(L.newProjectMsg)
        }
    }

    private func loadProjects() async {
        projects = (try? await service.fetchProjects()) ?? []
        if !projects.contains(where: { $0.name == selectedProject }) {
            selectedProject = projects.first?.name ?? "default"
        }
        await loadFiles(for: selectedProject)
    }

    private func loadFiles(for project: String) async {
        isLoadingFiles = true
        files = (try? await service.fetchProjectFiles(name: project)) ?? []
        isLoadingFiles = false
    }

    private func fileIcon(ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "globe"
        case "txt", "md": return "doc.text"
        case "json": return "curlybraces"
        case "csv": return "tablecells"
        case "xlsx", "xls": return "tablecells.fill"
        case "pdf": return "doc.richtext"
        case "py": return "terminal"
        case "js", "ts": return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        default: return "doc"
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
