import Foundation
import Postbox
import TelegramApi
import SwiftSignalKit

private struct SearchStickersConfiguration {
    static var defaultValue: SearchStickersConfiguration {
        return SearchStickersConfiguration(cacheTimeout: 86400, normalStickersPerPremium: 2, premiumStickersCount: 0)
    }
    
    public let cacheTimeout: Int32
    public let normalStickersPerPremiumCount: Int32
    public let premiumStickersCount: Int32
    
    fileprivate init(cacheTimeout: Int32, normalStickersPerPremium: Int32, premiumStickersCount: Int32) {
        self.cacheTimeout = cacheTimeout
        self.normalStickersPerPremiumCount = normalStickersPerPremium
        self.premiumStickersCount = premiumStickersCount
    }
    
    static func with(appConfiguration: AppConfiguration) -> SearchStickersConfiguration {
        if let data = appConfiguration.data, let cacheTimeoutValue = data["stickers_emoji_cache_time"] as? Double, let normalStickersPerPremiumValue = data["stickers_normal_by_emoji_per_premium_num"] as? Double, let premiumStickersCountValue = data["stickers_premium_by_emoji_num "] as? Double {
            return SearchStickersConfiguration(cacheTimeout: Int32(cacheTimeoutValue), normalStickersPerPremium: Int32(normalStickersPerPremiumValue), premiumStickersCount: Int32(premiumStickersCountValue))
        } else {
            return .defaultValue
        }
    }
}

public final class FoundStickerItem: Equatable {
    public let file: TelegramMediaFile
    public let stringRepresentations: [String]
    
    public init(file: TelegramMediaFile, stringRepresentations: [String]) {
        self.file = file
        self.stringRepresentations = stringRepresentations
    }
    
    public static func ==(lhs: FoundStickerItem, rhs: FoundStickerItem) -> Bool {
        if !lhs.file.isEqual(to: rhs.file) {
            return false
        }
        if lhs.stringRepresentations != rhs.stringRepresentations {
            return false
        }
        return true
    }
}

public struct SearchStickersScope: OptionSet {
    public var rawValue: Int32
    
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
    
    public static let installed = SearchStickersScope(rawValue: 1 << 0)
    public static let remote = SearchStickersScope(rawValue: 1 << 1)
}

func _internal_randomGreetingSticker(account: Account) -> Signal<FoundStickerItem?, NoError> {
    let key: PostboxViewKey = .orderedItemList(id: Namespaces.OrderedItemList.CloudGreetingStickers)
    return account.postbox.combinedView(keys: [key])
    |> map { views -> [OrderedItemListEntry]? in
        if let view = views.views[key] as? OrderedItemListView, !view.items.isEmpty {
            return view.items
        } else {
            return nil
        }
    }
    |> filter { items in
        return items != nil
    }
    |> take(1)
    |> map { items -> FoundStickerItem? in
        if let randomItem = items?.randomElement(), let item = randomItem.contents.get(RecentMediaItem.self) {
            let file = item.media
            return FoundStickerItem(file: file, stringRepresentations: [])
        }
        return nil
    }
}

func _internal_searchStickers(account: Account, query: [String], scope: SearchStickersScope = [.installed, .remote]) -> Signal<(items: [FoundStickerItem], isFinalResult: Bool), NoError> {
    if scope.isEmpty {
        return .single(([], true))
    }
    var query = query
    if query == ["\u{2764}"] {
        query = ["\u{2764}\u{FE0F}"]
    }
    
    return account.postbox.transaction { transaction -> ([FoundStickerItem], CachedStickerQueryResult?, Bool, SearchStickersConfiguration) in
        let isPremium = transaction.getPeer(account.peerId)?.isPremium ?? false
        
        var result: [FoundStickerItem] = []
        if scope.contains(.installed) {
            for entry in transaction.getOrderedListItems(collectionId: Namespaces.OrderedItemList.CloudSavedStickers) {
                if let item = entry.contents.get(SavedStickerItem.self) {
                    for representation in item.stringRepresentations {
                        for queryItem in query {
                            if representation.hasPrefix(queryItem) {
                                result.append(FoundStickerItem(file: item.file, stringRepresentations: item.stringRepresentations))
                                break
                            }
                        }
                    }
                }
            }
            
            var currentItems = Set<MediaId>(result.map { $0.file.fileId })
            var recentItems: [TelegramMediaFile] = []
            var recentAnimatedItems: [TelegramMediaFile] = []
            var recentItemsIds = Set<MediaId>()
            var matchingRecentItemsIds = Set<MediaId>()
            
            for entry in transaction.getOrderedListItems(collectionId: Namespaces.OrderedItemList.CloudRecentStickers) {
                if let item = entry.contents.get(RecentMediaItem.self) {
                    let file = item.media
                    if file.isPremiumSticker && !isPremium {
                        continue
                    }

                    if !currentItems.contains(file.fileId) {
                        currentItems.insert(file.fileId)
                        
                        for case let .Sticker(displayText, _, _) in file.attributes {
                            for queryItem in query {
                                if displayText.hasPrefix(queryItem) {
                                    matchingRecentItemsIds.insert(file.fileId)
                                    break
                                }
                            }
                            recentItemsIds.insert(file.fileId)
                            if file.isAnimatedSticker || file.isVideoSticker {
                                recentAnimatedItems.append(file)
                            } else {
                                recentItems.append(file)
                            }
                            break
                        }
                    }
                }
            }
            
            var searchQueries: [ItemCollectionSearchQuery] = query.map { queryItem -> ItemCollectionSearchQuery in
                return .exact(ValueBoxKey(queryItem))
            }
            if query == ["\u{2764}"] {
                searchQueries = [.any([ValueBoxKey("\u{2764}"), ValueBoxKey("\u{2764}\u{FE0F}")])]
            }
            
            var installedItems: [FoundStickerItem] = []
            var installedAnimatedItems: [FoundStickerItem] = []
            var installedPremiumItems: [FoundStickerItem] = []
            
            for searchQuery in searchQueries {
                for item in transaction.searchItemCollection(namespace: Namespaces.ItemCollection.CloudStickerPacks, query: searchQuery) {
                    if let item = item as? StickerPackItem {
                        if !currentItems.contains(item.file.fileId) {
                            currentItems.insert(item.file.fileId)
                            
                            var stringRepresentations: [String] = []
                            for key in item.indexKeys {
                                key.withDataNoCopy { data in
                                    if let string = String(data: data, encoding: .utf8) {
                                        stringRepresentations.append(string)
                                    }
                                }
                            }
                            if !recentItemsIds.contains(item.file.fileId) {
                                if item.file.isPremiumSticker {
                                    installedPremiumItems.append(FoundStickerItem(file: item.file, stringRepresentations: stringRepresentations))
                                } else if item.file.isAnimatedSticker || item.file.isVideoSticker {
                                    installedAnimatedItems.append(FoundStickerItem(file: item.file, stringRepresentations: stringRepresentations))
                                } else {
                                    installedItems.append(FoundStickerItem(file: item.file, stringRepresentations: stringRepresentations))
                                }
                            } else {
                                matchingRecentItemsIds.insert(item.file.fileId)
                            }
                        }
                    }
                }
            }
            
            for file in recentAnimatedItems {
                if file.isPremiumSticker && !isPremium {
                    continue
                }
                if matchingRecentItemsIds.contains(file.fileId) {
                    result.append(FoundStickerItem(file: file, stringRepresentations: query))
                }
            }
            
            for file in recentItems {
                if file.isPremiumSticker && !isPremium {
                    continue
                }
                if matchingRecentItemsIds.contains(file.fileId) {
                    result.append(FoundStickerItem(file: file, stringRepresentations: query))
                }
            }
            
            result.append(contentsOf: installedAnimatedItems)
            result.append(contentsOf: installedItems)
        }
        
        let combinedQuery = query.joined(separator: "")
        var cached = transaction.retrieveItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedStickerQueryResults, key: CachedStickerQueryResult.cacheKey(combinedQuery)))?.get(CachedStickerQueryResult.self)
        
        let currentTime = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
        let appConfiguration: AppConfiguration = transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration)?.get(AppConfiguration.self) ?? AppConfiguration.defaultValue
        let searchStickersConfiguration = SearchStickersConfiguration.with(appConfiguration: appConfiguration)
        
        if let currentCached = cached, currentTime > currentCached.timestamp + searchStickersConfiguration.cacheTimeout {
            cached = nil
        }
        
        return (result, cached, isPremium, searchStickersConfiguration)
    }
    |> mapToSignal { localItems, cached, isPremium, searchStickersConfiguration -> Signal<(items: [FoundStickerItem], isFinalResult: Bool), NoError> in
        if !scope.contains(.remote) {
            return .single((localItems, true))
        }
        
        var tempResult: [FoundStickerItem] = []
        let currentItemIds = Set<MediaId>(localItems.map { $0.file.fileId })
        
        var premiumItems: [FoundStickerItem] = []
        var otherItems: [FoundStickerItem] = []
        
        for item in localItems {
            if item.file.isPremiumSticker {
                premiumItems.append(item)
            } else {
                otherItems.append(item)
            }
        }
        
        if let cached = cached {
            var cachedItems: [FoundStickerItem] = []
            var cachedAnimatedItems: [FoundStickerItem] = []
            var cachedPremiumItems: [FoundStickerItem] = []
                        
            for file in cached.items {
                if !currentItemIds.contains(file.fileId) {
                    if file.isPremiumSticker {
                        cachedPremiumItems.append(FoundStickerItem(file: file, stringRepresentations: []))
                    } else if file.isAnimatedSticker || file.isVideoSticker {
                        cachedAnimatedItems.append(FoundStickerItem(file: file, stringRepresentations: []))
                    } else {
                        cachedItems.append(FoundStickerItem(file: file, stringRepresentations: []))
                    }
                }
            }
            
            otherItems.append(contentsOf: cachedAnimatedItems)
            otherItems.append(contentsOf: cachedItems)
            
            let allPremiumItems = premiumItems + cachedPremiumItems
            let allOtherItems = otherItems + cachedAnimatedItems + cachedItems
            
            if isPremium {
                let batchCount = Int(searchStickersConfiguration.normalStickersPerPremiumCount)
                if batchCount == 0 {
                    tempResult.append(contentsOf: allPremiumItems)
                    tempResult.append(contentsOf: allOtherItems)
                } else {
                    if allPremiumItems.isEmpty {
                        tempResult.append(contentsOf: allOtherItems)
                    } else {
                        var i = 0
                        for premiumItem in allPremiumItems {
                            if i < allOtherItems.count {
                                for j in i ..< min(i + batchCount, allOtherItems.count) {
                                    tempResult.append(allOtherItems[j])
                                }
                                i += batchCount
                            }
                            tempResult.append(premiumItem)
                        }
                        if i < allOtherItems.count {
                            for j in i ..< allOtherItems.count {
                                tempResult.append(allOtherItems[j])
                            }
                        }
                    }
                }
            } else {
                tempResult.append(contentsOf: allOtherItems)
                tempResult.append(contentsOf: allPremiumItems.prefix(max(0, Int(searchStickersConfiguration.premiumStickersCount))))
            }
        }
        
        let remote = account.network.request(Api.functions.messages.getStickers(emoticon: query.joined(separator: ""), hash: cached?.hash ?? 0))
        |> `catch` { _ -> Signal<Api.messages.Stickers, NoError> in
            return .single(.stickersNotModified)
        }
        |> mapToSignal { result -> Signal<(items: [FoundStickerItem], isFinalResult: Bool), NoError> in
            return account.postbox.transaction { transaction -> (items: [FoundStickerItem], isFinalResult: Bool) in
                switch result {
                    case let .stickers(hash, stickers):
                        var result: [FoundStickerItem] = []
                        let currentItemIds = Set<MediaId>(localItems.map { $0.file.fileId })
                        
                        var premiumItems: [FoundStickerItem] = []
                        var otherItems: [FoundStickerItem] = []
                        
                        for item in localItems {
                            if item.file.isPremiumSticker {
                                premiumItems.append(item)
                            } else {
                                otherItems.append(item)
                            }
                        }
                    
                        var foundItems: [FoundStickerItem] = []
                        var foundAnimatedItems: [FoundStickerItem] = []
                        var foundPremiumItems: [FoundStickerItem] = []
                    
                        var files: [TelegramMediaFile] = []
                        for sticker in stickers {
                            if let file = telegramMediaFileFromApiDocument(sticker), let id = file.id {
                                files.append(file)
                                if !currentItemIds.contains(id) {
                                    if file.isPremiumSticker {
                                        foundPremiumItems.append(FoundStickerItem(file: file, stringRepresentations: []))
                                    } else if file.isAnimatedSticker || file.isVideoSticker {
                                        foundAnimatedItems.append(FoundStickerItem(file: file, stringRepresentations: []))
                                    } else {
                                        foundItems.append(FoundStickerItem(file: file, stringRepresentations: []))
                                    }
                                }
                            }
                        }
                    
                        let allPremiumItems = premiumItems + foundPremiumItems
                        let allOtherItems = otherItems + foundAnimatedItems + foundItems
                        
                        if isPremium {
                            let batchCount = Int(searchStickersConfiguration.normalStickersPerPremiumCount)
                            if batchCount == 0 {
                                result.append(contentsOf: allPremiumItems)
                                result.append(contentsOf: allOtherItems)
                            } else {
                                if allPremiumItems.isEmpty {
                                    result.append(contentsOf: allOtherItems)
                                } else {
                                    var i = 0
                                    for premiumItem in allPremiumItems {
                                        if i < allOtherItems.count {
                                            for j in i ..< min(i + batchCount, allOtherItems.count) {
                                                result.append(allOtherItems[j])
                                            }
                                            i += batchCount
                                        }
                                        result.append(premiumItem)
                                    }
                                    if i < allOtherItems.count {
                                        for j in i ..< allOtherItems.count {
                                            result.append(allOtherItems[j])
                                        }
                                    }
                                }
                            }
                        } else {
                            result.append(contentsOf: allOtherItems)
                            result.append(contentsOf: allPremiumItems.prefix(max(0, Int(searchStickersConfiguration.premiumStickersCount))))
                        }
                    
                        let currentTime = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                        if let entry = CodableEntry(CachedStickerQueryResult(items: files, hash: hash, timestamp: currentTime)) {
                            transaction.putItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedStickerQueryResults, key: CachedStickerQueryResult.cacheKey(query.joined(separator: ""))), entry: entry)
                        }
                    
                        return (result, true)
                    case .stickersNotModified:
                        break
                }
                return (tempResult, true)
            }
        }
        return .single((tempResult, false))
        |> then(remote)
    }
}

func _internal_searchEmoji(account: Account, query: [String], scope: SearchStickersScope = [.installed, .remote]) -> Signal<(items: [FoundStickerItem], isFinalResult: Bool), NoError> {
    if scope.isEmpty {
        return .single(([], true))
    }
    var query = query
    if query == ["\u{2764}"] {
        query = ["\u{2764}\u{FE0F}"]
    }
    let combinedQuery = query.sorted().joined(separator: "")
    let querySet = Set(query)
    return account.postbox.transaction { transaction -> ([FoundStickerItem], CachedStickerQueryResult?, Bool, SearchStickersConfiguration) in
        let isPremium = transaction.getPeer(account.peerId)?.isPremium ?? false
        
        var result: [FoundStickerItem] = []
        if scope.contains(.installed) {
            var currentItems = Set<MediaId>()
            var installedItems: [FoundStickerItem] = []
            
            for info in transaction.getItemCollectionsInfos(namespace: Namespaces.ItemCollection.CloudEmojiPacks) {
                if let info = info.1 as? StickerPackCollectionInfo {
                    let items = transaction.getItemCollectionItems(collectionId: info.id)
                    for item in items {
                        if let item = item as? StickerPackItem {
                            let file = item.file
                            if !currentItems.contains(file.fileId) {
                                currentItems.insert(file.fileId)
                                
                                var stringRepresentations: [String] = []
                                for key in item.indexKeys {
                                    key.withDataNoCopy { data in
                                        if let string = String(data: data, encoding: .utf8) {
                                            stringRepresentations.append(string)
                                        }
                                    }
                                }
                                for stringRepresentation in stringRepresentations {
                                    if querySet.contains(stringRepresentation) {
                                        installedItems.append(FoundStickerItem(file: file, stringRepresentations: stringRepresentations))
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
            }
            result.append(contentsOf: installedItems)
        }
    
        var cached = transaction.retrieveItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedEmojiQueryResults, key: CachedStickerQueryResult.cacheKey(combinedQuery)))?.get(CachedStickerQueryResult.self)
        
        let currentTime = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
        let appConfiguration: AppConfiguration = transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration)?.get(AppConfiguration.self) ?? AppConfiguration.defaultValue
        let searchStickersConfiguration = SearchStickersConfiguration.with(appConfiguration: appConfiguration)
        
        if let currentCached = cached, currentTime > currentCached.timestamp + searchStickersConfiguration.cacheTimeout {
            cached = nil
        }
        return (result, cached, isPremium, searchStickersConfiguration)
    }
    |> mapToSignal { localItems, cached, isPremium, searchStickersConfiguration -> Signal<(items: [FoundStickerItem], isFinalResult: Bool), NoError> in
        if !scope.contains(.remote) {
            return .single((localItems, true))
        }
        
        var intermediateResult: [FoundStickerItem] = localItems
        var currentItemIds = Set<MediaId>(localItems.map { $0.file.fileId })
        if let cached = cached {
            for file in cached.items {
                if !currentItemIds.contains(file.fileId) {
                    currentItemIds.insert(file.fileId)
                    intermediateResult.append(FoundStickerItem(file: file, stringRepresentations: []))
                }
            }
        }
        
        let remote = account.network.request(Api.functions.messages.searchCustomEmoji(emoticon: query.joined(separator: ""), hash: cached?.hash ?? 0))
        |> `catch` { _ -> Signal<Api.EmojiList, NoError> in
            return .single(.emojiListNotModified)
        }
        |> mapToSignal { result -> Signal<(files: [TelegramMediaFile], hash: Int64)?, NoError> in
            switch result {
            case .emojiListNotModified:
                return .single(nil)
            case let .emojiList(hash, documentIds):
                return TelegramEngine(account: account).stickers.resolveInlineStickers(fileIds: documentIds)
                |> map { fileMap -> (files: [TelegramMediaFile], hash: Int64)? in
                    var files: [TelegramMediaFile] = []
                    for documentId in documentIds {
                        if let file = fileMap[documentId] {
                            files.append(file)
                        }
                    }
                    return (files, hash)
                }
            }
        }
        |> mapToSignal { result -> Signal<(items: [FoundStickerItem], isFinalResult: Bool), NoError> in
            return account.postbox.transaction { transaction -> (items: [FoundStickerItem], isFinalResult: Bool) in
                if let (fileItems, hash) = result {
                    var result: [FoundStickerItem] = localItems
                    var currentItemIds = Set<MediaId>(localItems.map { $0.file.fileId })

                    var files: [TelegramMediaFile] = []
                    for file in fileItems {
                        files.append(file)
                        if !currentItemIds.contains(file.fileId) {
                            currentItemIds.insert(file.fileId)
                            result.append(FoundStickerItem(file: file, stringRepresentations: []))
                        }
                    }
                
                    let currentTime = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                    if let entry = CodableEntry(CachedStickerQueryResult(items: files, hash: hash, timestamp: currentTime)) {
                        transaction.putItemCacheEntry(id: ItemCacheEntryId(collectionId: Namespaces.CachedItemCollection.cachedEmojiQueryResults, key: CachedStickerQueryResult.cacheKey(combinedQuery)), entry: entry)
                    }
                
                    return (result, true)
                }
                return (intermediateResult, true)
            }
        }
        return .single((intermediateResult, false))
        |> then(remote)
    }
}

public struct FoundStickerSets {
    public var infos: [(ItemCollectionId, ItemCollectionInfo, ItemCollectionItem?, Bool)]
    public let entries: [ItemCollectionViewEntry]
    public init(infos: [(ItemCollectionId, ItemCollectionInfo, ItemCollectionItem?, Bool)] = [], entries: [ItemCollectionViewEntry] = []) {
        self.infos = infos
        self.entries = entries
    }
    
    public func withUpdatedInfosAndEntries(infos: [(ItemCollectionId, ItemCollectionInfo, ItemCollectionItem?, Bool)], entries: [ItemCollectionViewEntry]) -> FoundStickerSets {
        let infoResult = self.infos + infos
        let entriesResult = self.entries + entries
        return FoundStickerSets(infos: infoResult, entries: entriesResult)
    }
    
    public func merge(with other: FoundStickerSets) -> FoundStickerSets {
        return FoundStickerSets(infos: self.infos + other.infos, entries: self.entries + other.entries)
    }
}

func _internal_searchStickerSetsRemotely(network: Network, query: String) -> Signal<FoundStickerSets, NoError> {
    return network.request(Api.functions.messages.searchStickerSets(flags: 0, q: query, hash: 0))
        |> mapError {_ in}
        |> mapToSignal { value in
            var index: Int32 = 1000
            switch value {
            case let .foundStickerSets(_, sets: sets):
                var result = FoundStickerSets()
                for set in sets {
                    let parsed = parsePreviewStickerSet(set, namespace: Namespaces.ItemCollection.CloudStickerPacks)
                    let values = parsed.1.map({ ItemCollectionViewEntry(index: ItemCollectionViewEntryIndex(collectionIndex: index, collectionId: parsed.0.id, itemIndex: $0.index), item: $0) })
                    result = result.withUpdatedInfosAndEntries(infos: [(parsed.0.id, parsed.0, parsed.1.first, false)], entries: values)
                    index += 1
                }
                return .single(result)
            default:
                break
            }
            
            return .complete()
        }
        |> `catch` { _ -> Signal<FoundStickerSets, NoError> in
            return .single(FoundStickerSets())
    }
}

func _internal_searchEmojiSetsRemotely(postbox: Postbox, network: Network, query: String) -> Signal<FoundStickerSets, NoError> {
    return network.request(Api.functions.messages.searchEmojiStickerSets(flags: 0, q: query, hash: 0))
    |> mapError {_ in}
    |> mapToSignal { value in
        var index: Int32 = 1000
        switch value {
        case let .foundStickerSets(_, sets: sets):
            var result = FoundStickerSets()
            for set in sets {
                let parsed = parsePreviewStickerSet(set, namespace: Namespaces.ItemCollection.CloudEmojiPacks)
                let values = parsed.1.map({ ItemCollectionViewEntry(index: ItemCollectionViewEntryIndex(collectionIndex: index, collectionId: parsed.0.id, itemIndex: $0.index), item: $0) })
                result = result.withUpdatedInfosAndEntries(infos: [(parsed.0.id, parsed.0, parsed.1.first, false)], entries: values)
                index += 1
            }
            return .single(result)
        default:
            break
        }
        
        return .complete()
    }
    |> `catch` { _ -> Signal<FoundStickerSets, NoError> in
        return .single(FoundStickerSets())
    }
    |> mapToSignal { result -> Signal<FoundStickerSets, NoError> in
        return postbox.combinedView(keys: [PostboxViewKey.itemCollectionInfos(namespaces: [Namespaces.ItemCollection.CloudEmojiPacks])])
        |> map { combinedView -> Set<ItemCollectionId> in
            var installed = Set<ItemCollectionId>()
            
            if let view = combinedView.views[PostboxViewKey.itemCollectionInfos(namespaces: [Namespaces.ItemCollection.CloudEmojiPacks])] as? ItemCollectionInfosView {
                var installedIds = Set<ItemCollectionId>()
                if let ids = view.entriesByNamespace[Namespaces.ItemCollection.CloudEmojiPacks] {
                    installedIds = Set(ids.map(\.id))
                }
                installed = installedIds.intersection(Set(result.infos.map(\.0)))
            }
            
            return installed
        }
        |> distinctUntilChanged
        |> map { installed -> FoundStickerSets in
            return FoundStickerSets(infos: result.infos.map { info in
                return (info.0, info.1, info.2, installed.contains(info.0))
            }, entries: result.entries)
        }
    }
}

func _internal_searchStickerSets(postbox: Postbox, query: String) -> Signal<FoundStickerSets, NoError> {
    return postbox.transaction { transaction -> Signal<FoundStickerSets, NoError> in
        let infos = transaction.getItemCollectionsInfos(namespace: Namespaces.ItemCollection.CloudStickerPacks)
        
        var collections: [(ItemCollectionId, ItemCollectionInfo)] = []
        var topItems: [ItemCollectionId: ItemCollectionItem] = [:]
        var entries: [ItemCollectionViewEntry] = []
        for info in infos {
            if let info = info.1 as? StickerPackCollectionInfo {
                let split = info.title.split(separator: " ")
                if !split.filter({$0.lowercased().hasPrefix(query.lowercased())}).isEmpty || info.shortName.lowercased().hasPrefix(query.lowercased()) {
                    collections.append((info.id, info))
                }
            }
        }
        var index: Int32 = 0
        
        for info in collections {
            let items = transaction.getItemCollectionItems(collectionId: info.0)
            let values = items.map({ ItemCollectionViewEntry(index: ItemCollectionViewEntryIndex(collectionIndex: index, collectionId: info.0, itemIndex: $0.index), item: $0) })
            entries.append(contentsOf: values)
            if let first = items.first {
                topItems[info.0] = first
            }
            index += 1
        }
        
        let result = FoundStickerSets(infos: collections.map { ($0.0, $0.1, topItems[$0.0], true) }, entries: entries)
        
        return .single(result)
    } |> switchToLatest
}

func _internal_searchGifs(account: Account, query: String, nextOffset: String = "") -> Signal<ChatContextResultCollection?, NoError> {
   return account.postbox.transaction { transaction -> String in
        let configuration = currentSearchBotsConfiguration(transaction: transaction)
        return configuration.gifBotUsername ?? "gif"
    } |> mapToSignal {
        return _internal_resolvePeerByName(account: account, name: $0) |> mapToSignal { result in
            guard case let .result(result) = result else {
                return .complete()
            }
            return .single(result)
        }
    } |> filter { $0 != nil }
    |> map { $0! }
    |> mapToSignal { peerId -> Signal<Peer, NoError> in
        return account.postbox.loadedPeerWithId(peerId)
    }
    |> mapToSignal { peer -> Signal<ChatContextResultCollection?, NoError> in
        return _internal_requestChatContextResults(account: account, botId: peer.id, peerId: account.peerId, query: query, offset: nextOffset)
        |> map { results -> ChatContextResultCollection? in
            return results?.results
        }
        |> `catch` { error -> Signal<ChatContextResultCollection?, NoError> in
            return .single(nil)
        }
    }
}

extension TelegramMediaFile {
    var stickerString: String? {
        for attr in attributes {
            if case let .Sticker(displayText, _, _) = attr {
                return displayText
            }
        }
        return nil
    }
}
