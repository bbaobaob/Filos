//
//  ItemRow.swift
//  Filos
//
//  Created by lunginspector on 7/25/26.
//

import SwiftUI

struct ItemRow: View {
    @EnvironmentObject private var pmgr: PlistManager
    var item: PlistItem
    let hierarchy: Int
    
    var body: some View {
        Group {
            if item.type == .dict || item.type == .array || item.type == .data {
                HStack {
                    Text(item.key)
                        .overlay {
                            NavigationLink(destination: ModifyItemPage(item: item).environmentObject(pmgr)) {
                                EmptyView()
                            }
                            .opacity(0)
                        }
                    Spacer()
                    Button {
                       let _ = pmgr.toggleIsExpanded(items: &pmgr.plistArray, target: item)
                    } label: {
                        HStack {
                            Text(item.type.label)
                            Image(systemName: "chevron.down")
                                .font(.body.weight(.semibold))
                                .imageScale(.small)
                                .frame(width: 24, height: 24, alignment: .center)
                                .rotationEffect(.degrees(item.isExpanded ? 0 : -90))
                                .animation(.easeInOut(duration: 0.2), value: item.isExpanded)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listRowBackground(Color(uiColor: .hierarchyLevelColor(hierarchy)))
                // dictionary inception time
                if item.isExpanded {
                    if item.type == .data {
                        Text(item.stringVal)
                            .font(.system(size: 10, design: .monospaced))
                            .listRowBackground(Color(uiColor: .hierarchyLevelColor(hierarchy + 1)))
                    } else {
                        ForEach(item.dictVal.sorted(by: { $0.key < $1.key })) { item in
                            ItemRow(item: item, hierarchy: hierarchy + 1).environmentObject(pmgr)
                        }
                    }
                }
            } else {
                NavigationLink(destination: ModifyItemPage(item: item).environmentObject(pmgr)) {
                    HStack {
                        Text(item.key)
                        Spacer()
                        Text(item.stringVal)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color(uiColor: .hierarchyLevelColor(hierarchy)))
            }
        }
        .contextMenu {
            Menu {
                Button("Key") {
                    UIPasteboard.general.string = item.key
                }
                
                Button("Value") {
                    UIPasteboard.general.string = item.stringVal
                }
            } label: {
                Label("Copy...", systemImage: "doc.on.doc")
            }
        }
    }
}
