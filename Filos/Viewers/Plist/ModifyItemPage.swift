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
    @Environment(\.dismiss) var dismiss
    
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
                        if type != .unknown {
                            Text(type.label).id(type)
                        }
                    }
                }
                .disabled(!isEditing)
            } header: {
                HeaderLabel(text: "Identity", icon: "creditcard")
            }
            
            Section {
                switch item.type {
                case .dict, .array:
                    Button("Add Item") {
                        item.dictVal.insert(PlistItem(key: "New Item", value: ""), at: 0)
                    }
                    .disabled(!isEditing)
                    ForEach(item.dictVal.sorted(by: { $0.key < $1.key })) { nestItem in
                        ItemRow(item: nestItem, hierarchy: 0).environmentObject(pmgr)
                            .disabled(isEditing && nestItem.key == "New Item")
                            .swipeActions {
                                if isEditing {
                                    Button(role: .destructive) {
                                        item.dictVal.removeAll { $0.id == nestItem.id }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                }
                            }
                    }
                case .data:
                    TextEditor(text: $item.stringVal)
                        .frame(height: 400)
                        .disabled(!isEditing)
                case .bool:
                    Toggle(item.boolVal.description.uppercased(), isOn: $item.boolVal)
                default:
                    TextField(item.type.label, text: $item.stringVal)
                        .disabled(!isEditing)
                }
            } header: {
                if item.type == .dict || item.type == .array {
                    HeaderLabel(text: "Value (\(item.dictVal.count) items)", icon: "character.cursor.ibeam")
                } else {
                    HeaderLabel(text: "Value", icon: "character.cursor.ibeam")
                }
            }
            
            if isEditing {
                Button("Delete Item", role: .destructive) {
                    let _ = pmgr.writePlistItems(delItem: item)
                    dismiss()
                }
            }
        }
        .navigationTitle("\(item.key)")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditing)
        .onAppear {
            item = pmgr.plistArray.first(where: { $0.id == item.id }) ?? item
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isEditing {
                    Button {
                        item = pmgr.plistArray.first(where: { $0.id == item.id }) ?? item
                        isEditing = false
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                if isEditing {
                    Button(role: .adaptiveConfirm) {
                        let res = pmgr.writePlistItems(newItem: item)
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
}
