//
//  DataStack.swift
//  CoreStore
//
//  Copyright © 2014 John Rommel Estropia
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import CoreData
#if USE_FRAMEWORKS
    import GCDKit
#endif


// MARK: - DataStack

/**
 The `DataStack` encapsulates the data model for the Core Data stack. Each `DataStack` can have multiple data stores, usually specified as a "Configuration" in the model editor. Behind the scenes, the DataStack manages its own `NSPersistentStoreCoordinator`, a root `NSManagedObjectContext` for disk saves, and a shared `NSManagedObjectContext` designed as a read-only model interface for `NSManagedObjects`.
 */
public final class DataStack {
    
    /**
     Initializes a `DataStack` from the model with the specified `modelName` in the specified `bundle`.
     
     - parameter modelName: the name of the (.xcdatamodeld) model file. If not specified, the application name (CFBundleName) will be used if it exists, or "CoreData" if it the bundle name was not set.
     - parameter bundle: an optional bundle to load models from. If not specified, the main bundle will be used.
     - parameter migrationChain: the `MigrationChain` that indicates the sequence of model versions to be used as the order for progressive migrations. If not specified, will default to a non-migrating data stack.
     */
    public convenience init(modelName: String = DataStack.applicationName, bundle: NSBundle = NSBundle.mainBundle(), migrationChain: MigrationChain = nil) {
        
        let model = NSManagedObjectModel.fromBundle(
            bundle,
            modelName: modelName,
            modelVersionHints: migrationChain.leafVersions
        )
        self.init(model: model, migrationChain: migrationChain)
    }
    
    /**
     Initializes a `DataStack` from an `NSManagedObjectModel`.
     
     - parameter model: the `NSManagedObjectModel` for the stack
     - parameter migrationChain: the `MigrationChain` that indicates the sequence of model versions to be used as the order for progressive migrations. If not specified, will default to a non-migrating data stack.
     */
    public required init(model: NSManagedObjectModel, migrationChain: MigrationChain = nil) {
        
        CoreStore.assert(
            migrationChain.valid,
            "Invalid migration chain passed to the \(typeName(DataStack)). Check that the model versions' order is correct and that no repetitions or ambiguities exist."
        )
        
        self.coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        self.rootSavingContext = NSManagedObjectContext.rootSavingContextForCoordinator(self.coordinator)
        self.mainContext = NSManagedObjectContext.mainContextForRootContext(self.rootSavingContext)
        self.model = model
        self.migrationChain = migrationChain
        
        self.rootSavingContext.parentStack = self
    }
    
    /**
     Returns the `DataStack`'s model version. The version string is the same as the name of the version-specific .xcdatamodeld file.
     */
    public var modelVersion: String {
        
        return self.model.currentModelVersion!
    }
    
    /**
     Returns the entity name-to-class type mapping from the `DataStack`'s model.
     */
    public var entityTypesByName: [String: NSManagedObject.Type] {
        
        return self.model.entityTypesMapping()
    }
    
    /**
     Returns the `NSEntityDescription` for the specified `NSManagedObject` subclass.
     */
    public func entityDescriptionForType(type: NSManagedObject.Type) -> NSEntityDescription? {
        
        return NSEntityDescription.entityForName(
            self.model.entityNameForClass(type),
            inManagedObjectContext: self.mainContext
        )
    }
    
    /**
     Returns the `NSManagedObjectID` for the specified object URI if it exists in the persistent store.
     */
    public func objectIDForURIRepresentation(url: NSURL) -> NSManagedObjectID? {
        
        return self.coordinator.managedObjectIDForURIRepresentation(url)
    }
    
    /**
     Creates an `SQLiteStore` with default parameters and adds it to the stack. This method blocks until completion.
     ```
     try dataStack.addStorageAndWait()
     ```
     
     - returns: the local SQLite storage added to the stack
     */
    public func addStorageAndWait() throws -> SQLiteStore {
        
        return try self.addStorageAndWait(SQLiteStore)
    }
    
    /**
     Creates a `StorageInterface` of the specified store type with default values and adds it to the stack. This method blocks until completion.
     ```
     try dataStack.addStorageAndWait(InMemoryStore)
     ```
     
     - parameter storeType: the `StorageInterface` type
     - returns: the `StorageInterface` added to the stack
     */
    public func addStorageAndWait<T: StorageInterface where T: DefaultInitializableStore>(storeType: T.Type) throws -> T {
        
        return try self.addStorageAndWait(storeType.init())
    }
    
    /**
     Adds a `StorageInterface` to the stack and blocks until completion.
     ```
     try dataStack.addStorageAndWait(InMemoryStore(configuration: "Config1"))
     ```
     
     - parameter storage: the `StorageInterface`
     - returns: the `StorageInterface` added to the stack
     */
    public func addStorageAndWait<T: StorageInterface>(storage: T) throws -> T {
        
        do {
            
            return try self.coordinator.performBlockAndWait { () -> T in
                
                if let _ = self.persistentStoreForStorage(storage) {
                    
                    return storage
                }
                
                try self.createPersistentStoreFromStorage(storage, finalURL: nil)
                return storage
            }
        }
        catch {
            
            CoreStore.handleError(
                error as NSError,
                "Failed to add \(typeName(storage)) to the stack."
            )
            throw error
        }
    }
    
    /**
     Creates a `LocalStorageface` of the specified store type with default values and adds it to the stack. This method blocks until completion.
     ```
     try dataStack.addStorageAndWait(SQLiteStore)
     ```
     
     - parameter storeType: the `LocalStorageface` type
     - returns: the local storage added to the stack
     */
    public func addStorageAndWait<T: LocalStorage where T: DefaultInitializableStore>(storageType: T.Type) throws -> T {
        
        return try self.addStorageAndWait(storageType.init())
    }
    
    /**
     Adds a `LocalStorage` to the stack and blocks until completion.
     ```
     try dataStack.addStorageAndWait(SQLiteStore(configuration: "Config1"))
     ```
     
     - parameter storage: the local storage
     - returns: the local storage added to the stack. Note that this may not always be the same instance as the parameter argument if a previous `LocalStorage` was already added at the same URL and with the same configuration.
     */
    public func addStorageAndWait<T: LocalStorage>(storage: T) throws -> T {
        
        return try self.coordinator.performBlockAndWait {
            
            let fileURL = storage.fileURL
            CoreStore.assert(
                fileURL.fileURL,
                "The specified store URL for the \"\(typeName(storage))\" is invalid: \"\(fileURL)\""
            )
            
            if let _ = self.persistentStoreForStorage(storage) {
                
                return storage
            }
            
            if let persistentStore = self.coordinator.persistentStoreForURL(fileURL) {
                
                if let existingStorage = persistentStore.storageInterface as? T
                    where storage.matchesPersistentStore(persistentStore) {
                    
                    return existingStorage
                }
                
                let error = NSError(coreStoreErrorCode: .DifferentPersistentStoreExistsAtURL)
                CoreStore.handleError(
                    error,
                    "Failed to add \(typeName(storage)) at \"\(fileURL)\" because a different \(typeName(NSPersistentStore)) at that URL already exists."
                )
                throw error
            }
            
            do {
                
                do {
                    
                    try NSFileManager.defaultManager().createDirectoryAtURL(
                        fileURL.URLByDeletingLastPathComponent!,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    try self.createPersistentStoreFromStorage(storage, finalURL: fileURL)
                    return storage
                }
                catch let error as NSError where storage.resetStoreOnModelMismatch && error.isCoreDataMigrationError {
                    
                    let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStoreOfType(
                        storage.dynamicType.storeType,
                        URL: fileURL,
                        options: storage.storeOptions
                    )
                    try _ = self.model[metadata].flatMap(storage.eraseStorageAndWait)
                    
                    try self.createPersistentStoreFromStorage(storage, finalURL: fileURL)
                    return storage
                }
            }
            catch {
                
                CoreStore.handleError(
                    error as NSError,
                    "Failed to add \(typeName(storage)) to the stack."
                )
                throw error
            }
        }
    }
    
    
    // MARK: Internal
    
    internal static let applicationName = (NSBundle.mainBundle().objectForInfoDictionaryKey("CFBundleName") as? String) ?? "CoreData"
    
    internal let coordinator: NSPersistentStoreCoordinator
    internal let rootSavingContext: NSManagedObjectContext
    internal let mainContext: NSManagedObjectContext
    internal let model: NSManagedObjectModel
    internal let migrationChain: MigrationChain
    internal let childTransactionQueue: GCDQueue = .createSerial("com.coreStore.dataStack.childTransactionQueue")
    internal let storeMetadataUpdateQueue = GCDQueue.createConcurrent("com.coreStore.persistentStoreBarrierQueue")
    internal let migrationQueue: NSOperationQueue = {
        
        let migrationQueue = NSOperationQueue()
        migrationQueue.maxConcurrentOperationCount = 1
        migrationQueue.name = "com.coreStore.migrationOperationQueue"
        migrationQueue.qualityOfService = .Utility
        migrationQueue.underlyingQueue = dispatch_queue_create("com.coreStore.migrationQueue", DISPATCH_QUEUE_SERIAL)
        return migrationQueue
    }()
    
    internal func persistentStoreForStorage(storage: StorageInterface) -> NSPersistentStore? {
        
        return self.coordinator.persistentStores
            .filter { $0.storageInterface === storage }
            .first
    }
    
    internal func entityNameForEntityClass(entityClass: AnyClass) -> String? {
        
        return self.model.entityNameForClass(entityClass)
    }
    
    internal func persistentStoresForEntityClass(entityClass: AnyClass) -> [NSPersistentStore]? {
        
        var returnValue: [NSPersistentStore]? = nil
        self.storeMetadataUpdateQueue.barrierSync {
            
            returnValue = self.entityConfigurationsMapping[NSStringFromClass(entityClass)]?.map {
                
                return self.configurationStoreMapping[$0]!
            } ?? []
        }
        return returnValue
    }
    
    internal func persistentStoreForEntityClass(entityClass: AnyClass, configuration: String?, inferStoreIfPossible: Bool) -> (store: NSPersistentStore?, isAmbiguous: Bool) {
        
        var returnValue: (store: NSPersistentStore?, isAmbiguous: Bool) = (store: nil, isAmbiguous: false)
        self.storeMetadataUpdateQueue.barrierSync {
            
            let configurationsForEntity = self.entityConfigurationsMapping[NSStringFromClass(entityClass)] ?? []
            if let configuration = configuration {
                
                if configurationsForEntity.contains(configuration) {
                    
                    returnValue = (store: self.configurationStoreMapping[configuration], isAmbiguous: false)
                    return
                }
                else if !inferStoreIfPossible {
                    
                    return
                }
            }
            
            switch configurationsForEntity.count {
                
            case 0:
                return
                
            case 1 where inferStoreIfPossible:
                returnValue = (store: self.configurationStoreMapping[configurationsForEntity.first!], isAmbiguous: false)
                
            default:
                returnValue = (store: nil, isAmbiguous: true)
            }
        }
        return returnValue
    }
    
    internal func createPersistentStoreFromStorage(storage: StorageInterface, finalURL: NSURL?) throws -> NSPersistentStore {
        
        let persistentStore = try self.coordinator.addPersistentStoreWithType(
            storage.dynamicType.storeType,
            configuration: storage.configuration,
            URL: finalURL,
            options: storage.storeOptions
        )
        persistentStore.storageInterface = storage
        
        self.storeMetadataUpdateQueue.barrierAsync {
            
            let configurationName = persistentStore.configurationName
            self.configurationStoreMapping[configurationName] = persistentStore
            for entityDescription in (self.coordinator.managedObjectModel.entitiesForConfiguration(configurationName) ?? []) {
                
                let managedObjectClassName = entityDescription.managedObjectClassName
                CoreStore.assert(
                    NSClassFromString(managedObjectClassName) != nil,
                    "The class \(typeName(managedObjectClassName)) for the entity \(typeName(entityDescription.name)) does not exist. Check if the subclass type and module name are properly configured."
                )
                
                if self.entityConfigurationsMapping[managedObjectClassName] == nil {
                    
                    self.entityConfigurationsMapping[managedObjectClassName] = []
                }
                self.entityConfigurationsMapping[managedObjectClassName]?.insert(configurationName)
            }
        }
        return persistentStore
    }
    
    
    // MARK: Private
    
    private var configurationStoreMapping = [String: NSPersistentStore]()
    private var entityConfigurationsMapping = [String: Set<String>]()
    
    deinit {
        
        let coordinator = self.coordinator
        coordinator.persistentStores.forEach { _ = try? coordinator.removePersistentStore($0) }
    }
    
    
    // MARK: Deprecated
    
    /**
     Deprecated. Use `addStorageAndWait(_:)` by passing a `InMemoryStore` instance.
     */
    @available(*, deprecated=2.0.0, message="Use addStorageAndWait(_:) by passing an InMemoryStore instance.")
    public func addInMemoryStoreAndWait(configuration configuration: String? = nil) throws -> NSPersistentStore {
        
        let storage = try self.addStorageAndWait(InMemoryStore(configuration: configuration))
        return storage.internalStore!
    }
    
    /**
     Deprecated. Use `addStorageAndWait(_:)` by passing a `LegacySQLiteStore` instance.
     
     - Warning: The default SQLite file location for the `LegacySQLiteStore` and `SQLiteStore` are different. If the app was using this method prior to 2.0.0, make sure to use `LegacySQLiteStore`.
     */
    @available(*, deprecated=2.0.0, message="Use addStorageAndWait(_:) by passing a LegacySQLiteStore instance. Warning: The default SQLite file location for the LegacySQLiteStore and SQLiteStore are different. If the app was using this method prior to 2.0.0, make sure to use LegacySQLiteStore.")
    public func addSQLiteStoreAndWait(fileName fileName: String, configuration: String? = nil, resetStoreOnModelMismatch: Bool = false) throws -> NSPersistentStore {
        
        let storage = try self.addStorageAndWait(
            LegacySQLiteStore(
                fileName: fileName,
                configuration: configuration,
                resetStoreOnModelMismatch: resetStoreOnModelMismatch
            )
        )
        return storage.internalStore!
    }
    
    /**
     Deprecated. Use `addStorageAndWait(_:)` by passing a `LegacySQLiteStore` instance.
     
     - Warning: The default SQLite file location for the `LegacySQLiteStore` and `SQLiteStore` are different. If the app was using this method prior to 2.0.0, make sure to use `LegacySQLiteStore`.
     */
    @available(*, deprecated=2.0.0, message="Use addStorageAndWait(_:) by passing a LegacySQLiteStore instance. Warning: The default SQLite file location for the LegacySQLiteStore and SQLiteStore are different. If the app was using this method prior to 2.0.0, make sure to use LegacySQLiteStore.")
    public func addSQLiteStoreAndWait(fileURL fileURL: NSURL = LegacySQLiteStore.legacyDefaultFileURL, configuration: String? = nil, resetStoreOnModelMismatch: Bool = false) throws -> NSPersistentStore {
        
        let storage = try self.addStorageAndWait(
            LegacySQLiteStore(
                fileURL: fileURL,
                configuration: configuration,
                resetStoreOnModelMismatch: resetStoreOnModelMismatch
            )
        )
        return storage.internalStore!
    }
}
