//
//  KeyRow.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import SwiftUI
import PartyUI

struct KeyRow: View {
    let key: String
    let value: Any?
    let hierarchy: Int
    
    @State private var nestedDict: [String: Any] = [:]
    @State private var showNestedDict = false
    @State private var showData = false
    
    var body: some View {
        if type == "Dictionary" || type == "Array" {
            LabeledContent {
                Button {
                    showNestedDict.toggle()
                } label: {
                    HStack {
                        Text(type)
                        Image(systemName: "chevron.down")
                            .frame(width: 24, height: 24, alignment: .center)
                            .rotationEffect(.degrees(showNestedDict ? 0 : -90))
                            .animation(.easeInOut(duration: 0.2), value: showNestedDict)
                    }
                }
                .foregroundStyle(Color(.label))
            } label: {
                Text(key)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
            .onAppear {
                if type == "Dictionary" {
                    nestedDict = value as? [String : Any] ?? [:]
                } else {
                    let array = value as? [Any] ?? []
                    
                    for (index, arrayVal) in array.enumerated() {
                        nestedDict["Item \(index)"] = arrayVal
                    }
                }
            }
            
            if showNestedDict {
                ForEach(nestedDict.keys.sorted(), id: \.self) { nestedKey in
                    KeyRow(key: nestedKey, value: nestedDict[nestedKey], hierarchy: hierarchy + 1)
                        .listRowBackground(Color(uiColor: .hierarchyLevelColor(hierarchy)))
                }
            }
            
        } else if type == "Data" {
            LabeledContent {
                Button {
                    showData.toggle()
                } label: {
                    HStack {
                        Text("Data")
                        Image(systemName: "chevron.down")
                            .frame(width: 24, height: 24, alignment: .center)
                            .rotationEffect(.degrees(showData ? 0 : -90))
                            .animation(.easeInOut(duration: 0.2), value: showData)
                    }
                }
                .foregroundStyle(Color(.label))
            } label: {
                Text(key)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if showData {
                Text(readableLabel(value))
                    .listRowBackground(Color(uiColor: .hierarchyLevelColor(hierarchy)))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = readableLabel(value)
                        } label: {
                            Label("Copy Data", systemImage: "externaldrive")
                        }
                    }
            }
        } else {
            LabeledContent {
                Text(readableLabel(value))
                    .foregroundStyle(.secondary)
            } label: {
                Text(key)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contextMenu {
                Text(type)
                
                Button {
                    UIPasteboard.general.string = key
                } label: {
                    Label("Copy Key", systemImage: "key")
                }
                
                Button {
                    UIPasteboard.general.string = readableLabel(value)
                } label: {
                    Label("Copy Value", systemImage: "character.cursor.ibeam")
                }
            }
        }
    }
    
    private var type: String {
        switch value {
        case is String: return "String"
        case is Int: return "Int"
        case is Double: return "Double"
        case is Bool: return "Bool"
        case is Data: return "Data"
        case is [String : Any]: return "Dictionary"
        case is [Any]: return "Array"
        default: return "Unknown"
        }
    }
    
    private func readableLabel(_ value: Any?) -> String {
        switch value {
        case let v as String: return v
        case let v as Int: return String(v)
        case let v as Double: return String(v)
        case let v as Bool: return v ? "True" : "False"
        case let v as Data: return v.base64EncodedString()
        default: return "Unknown"
        }
    }
}
