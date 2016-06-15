// Copyright 2016 The Tulsi Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Cocoa
import TulsiGenerator


final class TulsiProjectDocument: NSDocument,
                                  NSWindowDelegate,
                                  MessageLoggerProtocol,
                                  MessageLogProtocol,
                                  OptionsEditorModelProtocol,
                                  TulsiGeneratorConfigDocumentDelegate {

  enum Error: ErrorType {
    /// No config exists with the given name.
    case NoSuchConfig
    /// The config failed to load with the given debug info.
    case ConfigLoadFailed(String)
    /// The workspace used by the project is invalid due to the given debug info.
    case InvalidWorkspace(String)
  }

  /// Prefix used to access the persisted output folder for a given BUILD file path.
  static let ProjectOutputPathKeyPrefix = "projectOutput_"

  /// The subdirectory within a project bundle into which shareable generator configs will be
  /// stored.
  static let ProjectConfigsSubpath = "Configs"

  /// The project model.
  var project: TulsiProject! = nil

  /// Whether or not the document is currently performing a long running operation.
  dynamic var processing: Bool = false

  // The number of tasks that need to complete before processing is finished. May only be mutated on
  // the main queue.
  private var processingTaskCount: Int = 0 {
    didSet {
      assert(processingTaskCount >= 0, "Processing task count may never be negative")
      processing = processingTaskCount > 0
    }
  }

  /// The display names of generator configs associated with this project.
  dynamic var generatorConfigNames = [String]()

  /// Whether or not there are any opened generator config documents associated with this project.
  var hasChildConfigDocuments: Bool {
    return childConfigDocuments.count > 0
  }

  /// Documents controlling the generator configs associated with this project.
  private var childConfigDocuments = NSHashTable.weakObjectsHashTable()

  /// One rule per target in the BUILD files associated with this project.
  var ruleInfos: [RuleInfo] {
    return _ruleInfos
  }

  private var _ruleInfos = [RuleInfo]() {
    didSet {
      // Update the associated config documents.
      let childDocuments = childConfigDocuments.allObjects as! [TulsiGeneratorConfigDocument]
      for configDoc in childDocuments {
        configDoc.projectRuleInfos = ruleInfos
      }
    }
  }

  /// The set of Bazel packages associated with this project.
  dynamic var bazelPackages: [String]? {
    set {
      project!.bazelPackages = newValue ?? [String]()
      updateChangeCount(.ChangeDone)  // TODO(abaire): Implement undo functionality.
      updateRuleEntries()
    }
    get {
      return project?.bazelPackages
    }
  }

  /// Location of the bazel binary.
  dynamic var bazelURL: NSURL? {
    set {
      project.bazelURL = newValue
      if newValue != nil && infoExtractor != nil {
        infoExtractor.bazelURL = newValue!
      }
      updateChangeCount(.ChangeDone)  // TODO(abaire): Implement undo functionality.
      updateRuleEntries()
    }
    get {
      return project?.bazelURL
    }
  }

  /// Binding point for the directory containing the project's WORKSPACE file.
  dynamic var workspaceRootURL: NSURL? {
    return project?.workspaceRootURL
  }

  /// URL to the folder into which generator configs are saved.
  var generatorConfigFolderURL: NSURL? {
    return fileURL?.URLByAppendingPathComponent(TulsiProjectDocument.ProjectConfigsSubpath)
  }

  var infoExtractor: TulsiProjectInfoExtractor! = nil

  /// Array of user-facing messages, generally output by the Tulsi generator.
  dynamic var messages = [UIMessage]()

  lazy var bundleExtension: String = {
    TulsiProjectDocument.getTulsiBundleExtension()
  }()

  static func getTulsiBundleExtension() -> String {
    let bundle = NSBundle(forClass: self)
    let documentTypes = bundle.infoDictionary!["CFBundleDocumentTypes"] as! [[String: AnyObject]]
    let extensions = documentTypes.first!["CFBundleTypeExtensions"] as! [String]
    return extensions.first!
  }

  func clearMessages() {
    messages.removeAll(keepCapacity: true)
  }

  func addBUILDFileURL(buildFile: NSURL) -> Bool {
    guard let package = packageForBUILDFile(buildFile) else {
      return false
    }
    bazelPackages!.append(package)
    updateRuleEntries()
    return true
  }

  func containsBUILDFileURL(buildFile: NSURL) -> Bool {
    guard let package = packageForBUILDFile(buildFile),
              concreteBazelPackages = bazelPackages else {
      return false
    }
    return concreteBazelPackages.contains(package)
  }

  func createNewProject(projectName: String, workspaceFileURL: NSURL) {
    willChangeValueForKey("bazelURL")
    willChangeValueForKey("bazelPackages")
    willChangeValueForKey("workspaceRootURL")

    // Default the bundleURL to a sibling of the selected workspace file.
    let bundleName = "\(projectName).\(bundleExtension)"
    let workspaceRootURL = workspaceFileURL.URLByDeletingLastPathComponent!
    let tempProjectBundleURL = workspaceRootURL.URLByAppendingPathComponent(bundleName)

    project = TulsiProject(projectName: projectName,
                           projectBundleURL: tempProjectBundleURL,
                           workspaceRootURL: workspaceRootURL)
    updateChangeCount(.ChangeDone)  // TODO(abaire): Implement undo functionality.

    didChangeValueForKey("bazelURL")
    didChangeValueForKey("bazelPackages")
    didChangeValueForKey("workspaceRootURL")
  }

  override func writeSafelyToURL(url: NSURL,
                                 ofType typeName: String,
                                 forSaveOperation saveOperation: NSSaveOperationType) throws {
    // Ensure that the project's URL is set to the location in which this document is being saved so
    // that relative paths can be set properly.
    project.projectBundleURL = url
    try super.writeSafelyToURL(url, ofType: typeName, forSaveOperation: saveOperation)
  }

  override class func autosavesInPlace() -> Bool {
    return true
  }

  override func prepareSavePanel(panel: NSSavePanel) -> Bool {
    panel.message = NSLocalizedString("Document_SelectTulsiProjectOutputFolderMessage",
                                      comment: "Message to show at the top of the Tulsi project save as panel, explaining what to do.")
    panel.canCreateDirectories = true
    panel.allowedFileTypes = ["com.google.tulsi.project"]
    panel.nameFieldStringValue = project.projectBundleURL.lastPathComponent!
    return true
  }

  override func fileWrapperOfType(typeName: String) throws -> NSFileWrapper {
    let contents = [String: NSFileWrapper]()
    let bundleFileWrapper = NSFileWrapper(directoryWithFileWrappers: contents)
    bundleFileWrapper.addRegularFileWithContents(try project.save(),
                                                 preferredFilename: TulsiProject.ProjectFilename)

    if let perUserData = try project.savePerUserSettings() {
      bundleFileWrapper.addRegularFileWithContents(perUserData,
                                                   preferredFilename: TulsiProject.perUserFilename)
    }

    let configsFolder: NSFileWrapper
    let reachableError: NSErrorPointer = nil
    if let existingConfigFolderURL = generatorConfigFolderURL
        where existingConfigFolderURL.checkResourceIsReachableAndReturnError(reachableError) {
      // Preserve any existing config documents.
      configsFolder = try NSFileWrapper(URL: existingConfigFolderURL,
                                        options:  NSFileWrapperReadingOptions())
    } else {
      // Add a placeholder Configs directory.
      configsFolder = NSFileWrapper(directoryWithFileWrappers: [:])
    }
    configsFolder.preferredFilename = TulsiProjectDocument.ProjectConfigsSubpath
    bundleFileWrapper.addFileWrapper(configsFolder)
    return bundleFileWrapper
  }

  override func readFromFileWrapper(fileWrapper: NSFileWrapper, ofType typeName: String) throws {
    guard let concreteFileURL = fileURL,
              projectFileWrapper = fileWrapper.fileWrappers?[TulsiProject.ProjectFilename],
              fileContents = projectFileWrapper.regularFileContents else {
      return
    }

    let additionalOptionData: NSData?
    if let perUserDataFileWrapper = fileWrapper.fileWrappers?[TulsiProject.perUserFilename] {
      additionalOptionData = perUserDataFileWrapper.regularFileContents
    } else {
      additionalOptionData = nil
    }
    project = try TulsiProject(data: fileContents,
                               projectBundleURL: concreteFileURL,
                               additionalOptionData: additionalOptionData)

    if let configsDir = fileWrapper.fileWrappers?[TulsiProjectDocument.ProjectConfigsSubpath],
           configFileWrappers = configsDir.fileWrappers
        where configsDir.directory {
      var configNames = [String]()
      for (_, fileWrapper) in configFileWrappers {
        if let filename = fileWrapper.filename
            where fileWrapper.regularFile &&
                TulsiGeneratorConfigDocument.isGeneratorConfigFilename(filename) {
          let name = (filename as NSString).stringByDeletingPathExtension
          configNames.append(name)
        }
      }

      generatorConfigNames = configNames.sort()
    }

    // Verify that the workspace is a valid one.
    let workspaceFile = project.workspaceRootURL.URLByAppendingPathComponent("WORKSPACE",
                                                                             isDirectory: false)
    var isDirectory = ObjCBool(false)
    if !NSFileManager.defaultManager().fileExistsAtPath(workspaceFile.path!,
                                                        isDirectory: &isDirectory) || isDirectory {
      let fmt = NSLocalizedString("Error_NoWORKSPACEFile",
                                  comment: "Error when project does not have a valid Bazel WORKSPACE file at %1$@.")
      error(String(format: fmt, workspaceFile.path!))
      throw Error.InvalidWorkspace("Missing WORKSPACE file at \(workspaceFile.path!)")
    }

    updateRuleEntries()
  }

  override func makeWindowControllers() {
    let storyboard = NSStoryboard(name: "Main", bundle: nil)
    let windowController = storyboard.instantiateControllerWithIdentifier("TulsiProjectDocumentWindow") as! NSWindowController
    windowController.contentViewController?.representedObject = self
    addWindowController(windowController)
  }

  override func willPresentError(error: NSError) -> NSError {
    // Track errors shown to the user for bug reporting purposes.
    self.info("Presented error: \(error)")
    return super.willPresentError(error)
  }

  /// Tracks the given document as a child of this project.
  func trackChildConfigDocument(document: TulsiGeneratorConfigDocument) {
    childConfigDocuments.addObject(document)
    // Ensure that the child document is aware of the project-level processing tasks.
    document.addProcessingTaskCount(processingTaskCount)
  }

  /// Closes any generator config documents associated with this project.
  func closeChildConfigDocuments() {
    let childDocuments = childConfigDocuments.allObjects as! [TulsiGeneratorConfigDocument]
    for configDoc in childDocuments {
      configDoc.close()
    }
    childConfigDocuments.removeAllObjects()
  }

  func deleteConfigsNamed(configNamesToRemove: [String]) {
    let fileManager = NSFileManager.defaultManager()

    var nameToDoc = [String: TulsiGeneratorConfigDocument]()
    for doc in childConfigDocuments.allObjects as! [TulsiGeneratorConfigDocument] {
      guard let name = doc.configName else { continue }
      nameToDoc[name] = doc
    }
    var configNames = Set<String>(generatorConfigNames)

    for name in configNamesToRemove {
      configNames.remove(name)
      if let doc = nameToDoc[name] {
        childConfigDocuments.removeObject(doc)
        doc.close()
      }
      if let url = urlForConfigNamed(name) {
        let errorInfo: String?
        do {
          try fileManager.removeItemAtURL(url)
          errorInfo = nil
        } catch let e as NSError {
          errorInfo = "Unexpected exception \(e.localizedDescription)"
        } catch {
          errorInfo = "Unexpected exception"
        }
        if let errorInfo = errorInfo {
          let fmt = NSLocalizedString("Error_ConfigDeleteFailed",
                                      comment: "Error when a TulsiGeneratorConfig named %1$@ could not be deleted. Details are provided as %2$@.")
          error(String(format: fmt, name, errorInfo))
        }
      }
    }

    generatorConfigNames = configNames.sort()
  }

  func urlForConfigNamed(name: String) -> NSURL? {
     return TulsiGeneratorConfigDocument.urlForConfigNamed(name,
                                                           inFolderURL: generatorConfigFolderURL)
  }

  /// Asynchronously loads a previously created config with the given name, invoking the given
  /// completionHandler on the main thread when the document is fully loaded.
  func loadConfigDocumentNamed(name: String,
                               completionHandler: (TulsiGeneratorConfigDocument? -> Void)) throws -> TulsiGeneratorConfigDocument {
    let doc = try loadSparseConfigDocumentNamed(name)
    doc.finishLoadingDocument(completionHandler)
    return doc
  }

  /// Sparsely loads a previously created config with the given name. The returned document may have
  /// unresolved label references.
  func loadSparseConfigDocumentNamed(name: String) throws -> TulsiGeneratorConfigDocument {
    guard let configURL = urlForConfigNamed(name) else {
      throw Error.NoSuchConfig
    }

    let documentController = NSDocumentController.sharedDocumentController()
    if let configDocument = documentController.documentForURL(configURL) as? TulsiGeneratorConfigDocument {
      return configDocument
    }

    do {
      let configDocument = try TulsiGeneratorConfigDocument.makeSparseDocumentWithContentsOfURL(configURL,
                                                                                                infoExtractor: infoExtractor,
                                                                                                messageLogger: self,
                                                                                                messageLog: self,
                                                                                                bazelURL: bazelURL)
      configDocument.projectRuleInfos = ruleInfos
      configDocument.delegate = self
      trackChildConfigDocument(configDocument)
      return configDocument
    } catch let e as NSError {
      throw Error.ConfigLoadFailed("Failed to load config from '\(configURL.path)' with error \(e.localizedDescription)")
    } catch {
      throw Error.ConfigLoadFailed("Unexpected exception loading config from '\(configURL.path)'")
    }
  }

  /// Displays a generic critical error message to the user with the given debug message.
  /// This should be used sparingly and only for messages that would indicate bugs in Tulsi.
  func generalError(debugMessage: String) {
    let fmt = NSLocalizedString("Error_GeneralCriticalFailure",
                                comment: "A general, critical failure without a more fitting descriptive message. Details are provided as %1$@.")
    error(String(format: fmt, debugMessage))
  }

  // MARK: - NSUserInterfaceValidations

  override func validateUserInterfaceItem(item: NSValidatedUserInterfaceItem) -> Bool {
    switch item.action() {
      case Selector("saveDocument:"):
        return true
      case Selector("saveDocumentAs:"):
        return true
      case Selector("renameDocument:"):
        return true
      case Selector("moveDocument:"):
        return true

      // Unsupported actions.
      case Selector("duplicateDocument:"):
        // TODO(abaire): Consider implementing and allowing project duplication.
        return false

      default:
        print("Unhandled menu action: \(item.action())")
    }
    return false
  }

  // MARK: - MessageLoggerProtocol

  func warning(message: String) {
    #if DEBUG
    print("W: \(message)")
    #endif

    NSThread.doOnMainQueue() {
      self.messages.append(UIMessage(text: message, type: .Warning))
    }
  }

  func error(message: String, details: String? = nil) {
    #if DEBUG
    print("E: \(message)")
    #endif

    NSThread.doOnMainQueue() {
      self.messages.append(UIMessage(text: message, type: .Error))
      // TODO(abaire): Implement better error handling, allowing recovery of a good state.
      ErrorAlertView.displayModalError(message, details: details)
    }
  }

  func info(message: String) {
    #if DEBUG
    print("I: \(message)")
    #endif

    NSThread.doOnMainQueue() {
      self.messages.append(UIMessage(text: message, type: .Info))
    }
  }

  // MARK: - TulsiGeneratorConfigDocumentDelegate

  func didNameTulsiGeneratorConfigDocument(document: TulsiGeneratorConfigDocument) {
    guard let configName = document.configName else { return }
    if !generatorConfigNames.contains(configName) {
      let configNames = (generatorConfigNames + [configName]).sort()
      generatorConfigNames = configNames
    }
  }

  func parentOptionSetForConfigDocument(_: TulsiGeneratorConfigDocument) -> TulsiOptionSet? {
    return optionSet
  }

  // MARK: - OptionsEditorModelProtocol

  var projectName: String? {
    guard let concreteProject = project else { return nil }
    return concreteProject.projectName
  }

  var optionSet: TulsiOptionSet? {
    guard let concreteProject = project else { return nil }
    return concreteProject.options
  }

  var projectValueColumnTitle: String {
    return NSLocalizedString("OptionsEditor_ColumnTitle_Project",
                             comment: "Title for the options editor column used to edit per-tulsiproj values.")
  }

  var defaultValueColumnTitle: String {
    return NSLocalizedString("OptionsEditor_ColumnTitle_Default",
                             comment: "Title for the options editor column used to display the built-in default values.")
  }

  var optionsTargetUIRuleEntries: [UIRuleInfo]? {
    return nil
  }

  // MARK: - Private methods

  private func processingTaskStarted() {
    NSThread.doOnMainQueue() {
      self.processingTaskCount += 1
      let childDocuments = self.childConfigDocuments.allObjects as! [TulsiGeneratorConfigDocument]
      for configDoc in childDocuments {
        configDoc.processingTaskStarted()
      }
    }
  }

  private func processingTaskFinished() {
    NSThread.doOnMainQueue() {
      self.processingTaskCount -= 1
      let childDocuments = self.childConfigDocuments.allObjects as! [TulsiGeneratorConfigDocument]
      for configDoc in childDocuments {
        configDoc.processingTaskFinished()
      }
    }
  }

  private func packageForBUILDFile(buildFile: NSURL) -> String? {
    guard let packageURL = buildFile.URLByDeletingLastPathComponent else {
      return nil
    }

    // If the relative path is a child of the workspace root return it.
    if let relativePath = project.workspaceRelativePathForURL(packageURL)
        where !relativePath.hasPrefix("/") && !relativePath.hasPrefix("..") {
      return relativePath
    }
    return nil
  }

  // Fetches target rule entries from the project's BUILD documents.
  private func updateRuleEntries() {
    guard let concreteBazelURL = bazelURL else {
      return
    }

    // TODO(abaire): Cancel any outstanding update operations.
    processingTaskStarted()
    infoExtractor = TulsiProjectInfoExtractor(bazelURL: concreteBazelURL,
                                              project: project,
                                              messageLogger: self)

    NSThread.doOnQOSUserInitiatedThread() {
      let updatedRuleEntries = self.infoExtractor.extractTargetRules()
      NSThread.doOnMainQueue() {
        self._ruleInfos = updatedRuleEntries
        self.processingTaskFinished()
      }
    }
  }
}


/// Convenience class for displaying an error message with an optional detail accessory view.
class ErrorAlertView: NSAlert {
  dynamic var text = ""

  static func displayModalError(message: String, details: String? = nil) {
    let alert = ErrorAlertView()
    alert.messageText = "\(message)\n\nA fatal error occurred. Please check the message window " +
        "and file a bug if appropriate."
    alert.alertStyle = .CriticalAlertStyle

    if let details = details {
      alert.text = details

      var views: NSArray?
      NSBundle.mainBundle().loadNibNamed("ErrorAlertDetailView",
                                         owner: alert,
                                         topLevelObjects: &views)
      // Note: topLevelObjects will contain the accessory view and an NSApplication object in a
      // non-deterministic order.
      views = views?.filter() { $0 is NSView }
      if let accessoryView = views?.firstObject as? NSScrollView {
        alert.accessoryView = accessoryView
      } else {
        assertionFailure("Failed to load accessory view for error alert.")
      }
    }
    alert.runModal()
  }
}
