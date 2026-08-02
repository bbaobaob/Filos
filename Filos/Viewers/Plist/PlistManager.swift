//
//  PlistManager.swift
//  Filos
//
//  Created by lunginspector on 7/25/26.
//

import SwiftUI
import Combine

/*
 gonna be building the plist plist editor ever in pure swift. i am totally cut out to do this job. anyways, here's the general premise:
 we interpret a plist as [String : Any] and convert it to our own format. this'll make actually editing it way easier, at the cost of it still fucking sucking.
 
 PlistItem - a representation of an item inside of that plist
    init(key: String, value: Any) - converts from [String : Any] to [PlistItem]
    .getRawValue() - converts from [PlistItem] to Any
 
 plistArray - the source of truth for the plist that's being viewed or edited.
 loadPlistItems() - loads in plistDict.
 writePlistItem() - converts plistDict to [String : Any] and writes it.
 
 these functions are lovely and all, but here's the part that's actually annoying: the user interface.
 now, you may be thinking: lunginpsector, you've been doing SwiftUI for at least a year now. you should be good at this.
 no i'm not.
 if anything i'm more proud of the backend over whatever the frontend is gonna look like.
 
 here's my plan for the ui:
 Sheet -> PlistViewer (parent + NavigationStack): load plist using internal functions and then list out ItemRows for the whole dict. this means you can easily collapse/expand dictionary and array sections too.
    ItemRow -> NavigationLink -> ModifyItemPage: it is VITAL that there's a source of truth that's binded to the original plist, and that we create a binding that writes back into plistArray. this also means that plistArray and the actual [String : Any] plist may become out of sync. it can't be that hard to avoid that though, right? can't be. you edit stringVal, boolVal, and dictVal, then when you're done editing, since that binding thingy is going to plistArray, just running pmgr.writePlistItems() should work. this means we'll have to have an observableobject. i'm good with those.
 */

final class PlistManager: ObservableObject {
    static let shared = PlistManager()
    
    @Published var plistArray: [PlistItem] = []
    @Published var url: URL = URL.documentsDirectory.appendingPathComponent("oops")
    
    init() {}
    
    func loadPlistItems() -> Bool {
        plistArray = [PlistItem(key: "Root", value: [], isExpanded: true)]
        if let rawDict = getFileDict(url) {
            for key in rawDict.keys {
                if let value = rawDict[key] {
                    plistArray[0].dictVal.append(PlistItem(key: key, value: value))
                }
            }
            return true
        } else {
            print("[!] failed to load plist as it seems like there was no passable dictionary?")
        }
        return false
    }
    
    func writePlistItems(newItem: PlistItem? = nil, delItem: PlistItem? = nil) -> Bool {
        if let newItem {
            let res = replacePlistItem(items: &plistArray, newItem: newItem)
            if !res {
                print("[!] failed to write plist: couldn't find \(newItem.key) in dictionary.")
            }
        }
        
        if let delItem {
            let res = deletePlistItem(items: &plistArray, target: delItem)
            if !res {
                print("[!] failed to write plist: couldn't find \(delItem.key) in dictionary.")
            }
        }
        
        var dictToWrite: [String : Any] = [:]
        
        for item in plistArray[0].dictVal {
            dictToWrite[item.key] = item.getRawValue()
        }
    
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dictToWrite, format: .binary, options: 0)
            try data.write(to: url)
            return true
        } catch {
            print("[!] failed to write plist: \(error)")
        }
        return false
    }
    
    func replacePlistItem(items: inout [PlistItem], newItem: PlistItem) -> Bool {
        for item in items.indices {
            if items[item].id == newItem.id {
                items[item] = newItem
                return true
            }
            
            if replacePlistItem(items: &items[item].dictVal, newItem: newItem) {
                return true
            }
        }
        return false
    }
    
    func deletePlistItem(items: inout [PlistItem], target: PlistItem) -> Bool {
        for item in items.indices {
            if items[item].id == target.id {
                items.removeAll() { $0.id == target.id }
                return true
            }
            
            if deletePlistItem(items: &items[item].dictVal, target: target) {
                return true
            }
        }
        return false
    }
    
    func toggleIsExpanded(items: inout [PlistItem], target: PlistItem) -> Bool {
        for item in items.indices {
            if items[item].key == target.key {
                items[item].isExpanded.toggle()
                return true
            }
            
            if toggleIsExpanded(items: &items[item].dictVal, target: target) {
                return true
            }
        }
        return false
    }
}

struct PlistItem: Identifiable {
    var id = UUID()
    var key: String
    var rawVal: Any?
    var type: PlistItemType = .unknown
    var index: Int?
    var isExpanded: Bool
    
    var stringVal: String = ""
    var boolVal: Bool = false
    var dictVal: [PlistItem] = []
    
    init(key: String, value: Any, isExpanded: Bool = false) {
        self.key = key
        self.rawVal = value
        self.isExpanded = isExpanded
        self.type = getType()
        
        switch rawVal {
        case let v as String: self.stringVal = v
        case let v as Int: self.stringVal = String(v)
        case let v as Double: self.stringVal = String(v)
        case let v as Bool: self.boolVal = v
        case let v as Data: self.stringVal = v.base64EncodedString()
        case let v as [String : Any]:
            self.dictVal = v.map {
                PlistItem(key: $0.key, value: $0.value)
            }
            self.stringVal = v.description
        case let v as [Any]:
            self.dictVal = v.enumerated().map { index, value in
                var newItem = PlistItem(key: "Item \(index)", value: value)
                newItem.index = index
                return newItem
            }
            self.stringVal = v.description
        default: break
        }
    }
    
    private func getType() -> PlistItemType {
        switch rawVal {
        case is String: return .string
        case is Int: return .int
        case is Double: return .double
        case is Bool: return .bool
        case is Data: return .data
        case is [String : Any]: return .dict
        case is [Any]: return .array
        default: return .unknown
        }
    }
    
    func getRawValue() -> Any {
        switch type {
        case .string: return stringVal
        case .int: return Int(stringVal) ?? 0
        case .double: return Double(stringVal) ?? 0
        case .bool: return boolVal
        case .data: return Data(stringVal.utf8)
        case .dict:
            var rawDict = [String : Any]()
            for item in dictVal {
                rawDict[item.key] = item.getRawValue()
            }
            return rawDict
        case .array:
            var rawArray = [Any]()
            for item in dictVal {
                rawArray.append(item.getRawValue())
            }
            return rawArray
        case .unknown: return ""
        }
    }
}

enum PlistItemType: String, CaseIterable {
    case string, int, double, bool, data, dict, array, unknown
    
    var label: String {
        switch self {
        case .string: return "String"
        case .int: return "Integer"
        case .double: return "Double"
        case .bool: return "Boolean"
        case .data: return "Data"
        case .dict: return "Dictionary"
        case .array: return "Array"
        default: return "Unknown"
        }
    }
}
