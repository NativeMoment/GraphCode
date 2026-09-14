import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

@Suite
struct SettingsTemplateEntryTests {
  private func withStorage(_ body: (URL, TemplateStorage) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("settings-templates-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = TemplateStorage(
      homeDirectory: root.appendingPathComponent(".graphcode/templates", isDirectory: true))
    try body(root, storage)
  }

  @Test
  func homeDirectoryAsARecentProjectLoadsEachFileOnce() throws {
    try withStorage { root, storage in
      let template = PromptTemplate(name: "Home", body: "A personal brief.")
      try storage.save(template, to: .home, projectPath: nil)

      let entries = SettingsTemplateEntry.load(
        storage: storage, projectPaths: [root.path], graphs: [])

      #expect(entries.count == 1)
      #expect(entries.first?.template.id == template.id)
      #expect(entries.first?.template.origin == .home)
    }
  }

  @Test
  func repeatedAndSymlinkedProjectsLoadEachFileOnce() throws {
    try withStorage { root, storage in
      let project = root.appendingPathComponent("repo", isDirectory: true)
      let alias = root.appendingPathComponent("alias", isDirectory: true)
      try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
      let template = PromptTemplate(name: "Project", body: "A project brief.")
      try storage.save(template, to: .project(project.path), projectPath: project.path)

      let entries = SettingsTemplateEntry.load(
        storage: storage, projectPaths: [project.path, project.path, alias.path], graphs: [])
      let aliased = SettingsTemplateEntry.load(
        storage: storage, projectPaths: [alias.path], graphs: [])

      #expect(entries.count == 1)
      #expect(entries.map(\.id) == aliased.map(\.id))
    }
  }

  @Test
  func symlinkedHomeProjectRetainsThePersonalOrigin() throws {
    try withStorage { root, storage in
      let alias = root.appendingPathComponent("home-alias", isDirectory: true)
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
      try storage.save(
        PromptTemplate(name: "Home", body: "A personal brief."), to: .home, projectPath: nil)

      let entries = SettingsTemplateEntry.load(
        storage: storage, projectPaths: [alias.path], graphs: [])

      #expect(entries.count == 1)
      #expect(entries.first?.template.origin == .home)
    }
  }

  @Test
  func separateFilesWithTheSameUUIDRemainIndividuallyAddressable() throws {
    try withStorage { _, storage in
      let first = PromptTemplate(name: "First", body: "The first brief.")
      let second = PromptTemplate(id: first.id, name: "Second", body: "The second brief.")
      try storage.save(first, to: .home, projectPath: nil)
      try storage.save(second, to: .home, projectPath: nil)

      let entries = SettingsTemplateEntry.load(storage: storage, projectPaths: [], graphs: [])

      #expect(entries.map(\.template.fileName) == ["first.md", "second.md"])
      #expect(entries.map(\.template.id) == [first.id, first.id])
      #expect(Set(entries.map(\.id)).count == 2)
      let selected = try #require(entries.last)
      var edited = selected.template
      edited.body = "Changed only the second file."
      try storage.update(edited, replacing: selected.template)
      #expect(storage.load(projectPath: nil).map(\.body) == [first.body, edited.body])
      try storage.delete(selected.template)
      #expect(storage.load(projectPath: nil).map(\.fileName) == ["first.md"])
    }
  }

  @Test
  func sharedUUIDsAcrossProjectsAndHomeKeepEveryFileAndUsage() throws {
    try withStorage { root, storage in
      let first = root.appendingPathComponent("first", isDirectory: true)
      let second = root.appendingPathComponent("second", isDirectory: true)
      let template = PromptTemplate(name: "Shared", body: "A shared brief.")
      try storage.save(template, to: .home, projectPath: nil)
      for project in [first, second] {
        try storage.save(template, to: .project(project.path), projectPath: project.path)
      }
      let graph = LoopGraph(
        project: ProjectRef(path: first.path, name: "First"),
        nodes: IdentifiedArray(uniqueElements: [
          LoopNode(
            title: "Follower", loopType: .timeBased,
            templateFollow: TemplateFollow(id: template.id, name: template.name)),
          LoopNode(title: "Snapshot", createdFromTemplateID: template.id),
        ]))

      let entries = SettingsTemplateEntry.load(
        storage: storage, projectPaths: [first.path, second.path], graphs: [graph])

      #expect(
        entries.map(\.template.origin) == [.project(first.path), .project(second.path), .home])
      #expect(entries.map(\.template.id) == [template.id, template.id, template.id])
      #expect(Set(entries.map(\.id)).count == 3)
      #expect(entries.allSatisfy { $0.usage == TemplateUsage(following: 1, snapshots: 1) })
    }
  }

  @Test
  func fileSymlinksDoNotAddAnotherRow() throws {
    try withStorage { _, storage in
      try storage.save(
        PromptTemplate(name: "Original", body: "One file."), to: .home, projectPath: nil)
      let original = storage.homeDirectory.appendingPathComponent("original.md")
      try FileManager.default.createSymbolicLink(
        at: storage.homeDirectory.appendingPathComponent("linked.md"),
        withDestinationURL: original)

      let entries = SettingsTemplateEntry.load(storage: storage, projectPaths: [], graphs: [])

      #expect(entries.count == 1)
      #expect(entries.first?.id == original.standardizedFileURL.resolvingSymlinksInPath())
    }
  }

  @Test
  func missingTemplateDirectoriesAreAnEmptyLibrary() throws {
    try withStorage { root, storage in
      #expect(
        SettingsTemplateEntry.load(
          storage: storage, projectPaths: [root.appendingPathComponent("missing").path], graphs: []
        )
        .isEmpty)
    }
  }
}
