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
    
    @State private var showNest = false
    
    var body: some View {
        Group {
            if item.type == .dict || item.type == .array || item.type == .data {
                HStack {
                    Text(item.key)
                    Spacer()
                    Button {
                        showNest.toggle()
                    } label: {
                        HStack {
                            Text(item.type.label)
                            Image(systemName: "chevron.down")
                                .font(.body.weight(.semibold))
                                .imageScale(.small)
                                .frame(width: 24, height: 24, alignment: .center)
                                .rotationEffect(.degrees(showNest ? 0 : -90))
                                .animation(.easeInOut(duration: 0.2), value: showNest)
                        }
                    }
                }
                .listRowBackground(Color(uiColor: .hierarchyLevelColor(hierarchy)))
                // dictionary inception time
                if showNest {
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
                    }
                }
                .listRowBackground(Color(uiColor: .hierarchyLevelColor(hierarchy)))
            }
        }
        .contextMenu {
            NavigationLink(destination: ModifyItemPage(item: item).environmentObject(pmgr)) {
                Label("Modify Value", systemImage: "pencil")
            }
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
