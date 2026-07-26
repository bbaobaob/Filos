//
//  ModifyItemPage.swift
//  Filos
//
//  Created by lunginspector on 7/25/26.
//

import SwiftUI
import PartyUI

struct ModifyItemPage: View {
    @EnvironmentObject private var pmgr: PlistManager
    
    @State var item: PlistItem
    @State private var isEditing = false
    
    var body: some View {
        List {
            Section {
                if isEditing {
                    TextField("Key", text: $item.key)
                } else {
                    Text(item.key)
                }
                Picker("Type", selection: $item.type) {
                    ForEach(PlistItemType.allCases, id: \.self) { type in
                        Text(type.label).id(type)
                    }
                }
            } header: {
                HeaderLabel(text: "Identity", icon: "creditcard")
            }
            
            Section {
                switch item.type {
                case .dict, .array:
                    ForEach(item.dictVal) { item in
                        ItemRow(item: item, hierarchy: 0).environmentObject(pmgr)
                            .swipeActions {
                                Button {
                                    pmgr.plistArray.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                    }
                    Button("Add Key") {
                        item.dictVal[0] = PlistItem(key: "New Item", value: "")
                    }
                case .data:
                    TextEditor(text: $item.stringVal)
                        .frame(maxHeight: .infinity)
                default:
                    TextField(item.type.label, text: $item.stringVal)
                }
            } header: {
                if item.type == .dict || item.type == .array {
                    Text("\(item.dictVal.count) items")
                }
            }
        }
        .navigationTitle("\(item.key)")
        .toolbar {
            if isEditing {
                Button {
                    item = pmgr.plistArray.first(where: { $0.id == item.id }) ?? item
                    isEditing = false
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                
                Button(role: .adaptiveConfirm) {
                    if let index = pmgr.plistArray.firstIndex(where: { $0.id == item.id }) {
                        pmgr.plistArray[index] = item
                    }
                    let res = pmgr.writePlistItems()
                    if res {
                        Haptic.shared.play(.soft)
                    } else {
                        Alertinator.shared.alert(title: "Failed to write plist items!", body: "Check error logs for more detailed information.")
                    }
                    isEditing = false
                } label: {
                    Label("Apply", systemImage: "checkmark")
                }
            } else {
                Button {
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
            }
        }
    }
}
