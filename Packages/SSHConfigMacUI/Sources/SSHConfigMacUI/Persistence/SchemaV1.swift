import Foundation
import SwiftData

nonisolated enum SchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SettingModel.self,
            TunnelModel.self,
            PortMappingModel.self,
            HostGroupModel.self,
            HostMetadataModel.self,
            HostKeyCheckModel.self,
            ConfigBlobModel.self,
            ConfigVersionModel.self,
            ConfigVersionFileModel.self,
        ]
    }

    @Model
    nonisolated final class SettingModel {
        #Unique<SettingModel>([\.key])

        var key: String
        var value: String

        init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    @Model
    nonisolated final class TunnelModel {
        #Unique<TunnelModel>([\.tunnelID])

        var tunnelID: UUID
        var position: Int
        var name: String
        var hostAlias: String
        var mode: String
        var autostart: Bool
        @Relationship(deleteRule: .cascade, inverse: \PortMappingModel.tunnel)
        var mappings: [PortMappingModel] = []

        init(tunnelID: UUID, position: Int, name: String, hostAlias: String, mode: String, autostart: Bool) {
            self.tunnelID = tunnelID
            self.position = position
            self.name = name
            self.hostAlias = hostAlias
            self.mode = mode
            self.autostart = autostart
        }
    }

    @Model
    nonisolated final class PortMappingModel {
        var mappingID: UUID
        var position: Int
        var bindAddress: String
        var listenPort: Int
        var targetHost: String
        var targetPort: Int
        var hasWebUI: Bool
        var tunnel: TunnelModel?

        init(
            mappingID: UUID, position: Int, bindAddress: String, listenPort: Int,
            targetHost: String, targetPort: Int, hasWebUI: Bool
        ) {
            self.mappingID = mappingID
            self.position = position
            self.bindAddress = bindAddress
            self.listenPort = listenPort
            self.targetHost = targetHost
            self.targetPort = targetPort
            self.hasWebUI = hasWebUI
        }
    }

    @Model
    nonisolated final class HostGroupModel {
        #Unique<HostGroupModel>([\.groupID])

        var groupID: UUID
        var name: String
        var filePath: String?
        var sortIndex: Int

        init(groupID: UUID, name: String, filePath: String?, sortIndex: Int) {
            self.groupID = groupID
            self.name = name
            self.filePath = filePath
            self.sortIndex = sortIndex
        }
    }

    @Model
    nonisolated final class HostMetadataModel {
        #Unique<HostMetadataModel>([\.alias])

        var alias: String
        var isFavorite: Bool
        var tags: [String]

        init(alias: String, isFavorite: Bool, tags: [String]) {
            self.alias = alias
            self.isFavorite = isFavorite
            self.tags = tags
        }
    }

    @Model
    nonisolated final class HostKeyCheckModel {
        #Index<HostKeyCheckModel>([\.checkedAt], [\.groupID])

        var groupID: String
        var hostTitle: String
        var displayName: String
        var hostToken: String
        var keyType: String
        var fingerprint: String
        var serverOpenSSH: String
        var outcome: String
        var checkedAt: Date

        init(
            groupID: String, hostTitle: String, displayName: String, hostToken: String, keyType: String,
            fingerprint: String, serverOpenSSH: String, outcome: String, checkedAt: Date
        ) {
            self.groupID = groupID
            self.hostTitle = hostTitle
            self.displayName = displayName
            self.hostToken = hostToken
            self.keyType = keyType
            self.fingerprint = fingerprint
            self.serverOpenSSH = serverOpenSSH
            self.outcome = outcome
            self.checkedAt = checkedAt
        }
    }

    @Model
    nonisolated final class ConfigBlobModel {
        #Unique<ConfigBlobModel>([\.blobHash])

        var blobHash: String
        @Attribute(.externalStorage) var data: Data
        var size: Int

        init(blobHash: String, data: Data, size: Int) {
            self.blobHash = blobHash
            self.data = data
            self.size = size
        }
    }

    @Model
    nonisolated final class ConfigVersionModel {
        #Unique<ConfigVersionModel>([\.versionID])
        #Index<ConfigVersionModel>([\.createdAt], [\.parentID])

        var versionID: String
        var parentID: String?
        var createdAt: Date
        var name: String?
        var source: String
        var addedLines: Int
        var removedLines: Int
        var filesChanged: Int
        @Relationship(deleteRule: .cascade, inverse: \ConfigVersionFileModel.version)
        var files: [ConfigVersionFileModel] = []

        init(
            versionID: String, parentID: String?, createdAt: Date, name: String?, source: String,
            addedLines: Int, removedLines: Int, filesChanged: Int
        ) {
            self.versionID = versionID
            self.parentID = parentID
            self.createdAt = createdAt
            self.name = name
            self.source = source
            self.addedLines = addedLines
            self.removedLines = removedLines
            self.filesChanged = filesChanged
        }
    }

    @Model
    nonisolated final class ConfigVersionFileModel {
        var relativePath: String
        var blobHash: String
        var version: ConfigVersionModel?

        init(relativePath: String, blobHash: String) {
            self.relativePath = relativePath
            self.blobHash = blobHash
        }
    }
}

typealias SettingModel = SchemaV1.SettingModel
typealias TunnelModel = SchemaV1.TunnelModel
typealias PortMappingModel = SchemaV1.PortMappingModel
typealias HostGroupModel = SchemaV1.HostGroupModel
typealias HostMetadataModel = SchemaV1.HostMetadataModel
typealias HostKeyCheckModel = SchemaV1.HostKeyCheckModel
typealias ConfigBlobModel = SchemaV1.ConfigBlobModel
typealias ConfigVersionModel = SchemaV1.ConfigVersionModel
typealias ConfigVersionFileModel = SchemaV1.ConfigVersionFileModel

nonisolated enum PersistenceMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
