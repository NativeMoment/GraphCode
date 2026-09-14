import Foundation
import GraphcodeKit

/// Settings manages files, not just template UUIDs: copies in different projects
/// keep their UUID so following loops can still resolve them.
struct SettingsTemplateEntry: Identifiable {
  let id: URL
  let template: PromptTemplate
  let usage: TemplateUsage

  static func load(
    storage: TemplateStorage, projectPaths: [String], graphs: [LoopGraph]
  ) -> [Self] {
    // Opening the home folder as a project must not relabel its personal templates.
    let home = storage.homeDirectory.standardizedFileURL.resolvingSymlinksInPath()
    var seenDirectories: Set<URL> = [home]
    var found: [PromptTemplate] = []
    for path in projectPaths {
      let directory = storage.projectDirectory(path).standardizedFileURL.resolvingSymlinksInPath()
      guard seenDirectories.insert(directory).inserted else { continue }
      found += storage.load(projectPath: path).filter(\.origin.isProject)
    }
    found += storage.load(projectPath: nil)

    var seenFiles = Set<URL>()
    return TemplateLibraryClient.overlayUseCounts(found).compactMap { template in
      let directory: URL
      switch template.origin {
      case .home: directory = storage.homeDirectory
      case .project(let path): directory = storage.projectDirectory(path)
      }
      let id = directory.appendingPathComponent(template.fileName)
        .standardizedFileURL.resolvingSymlinksInPath()
      guard seenFiles.insert(id).inserted else { return nil }
      return Self(
        id: id,
        template: template,
        usage: TemplateUsage.of(template.id, in: graphs))
    }
  }
}
