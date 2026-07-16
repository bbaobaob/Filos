//
//  FavoritesSheet.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI
import PartyUI

struct FavoriteItem: Identifiable, Codable {
    var id: String { path }
    var label: String
    var path: String
}

struct FavoritesSheet: View {
    @Environment(\.dismiss) var dismiss
    @Binding var navPath: NavigationPath
    
    @AppStorage("favList") var favList: [FavoriteItem] = [
        FavoriteItem(label: "Blade Documents", path: URL.documentsDirectory.path)
    ]
    
    @State private var label: String = ""
    @State private var path: String = ""
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Label", text: $label)
                    TextField("File Path", text: $path)
                    
                    Button("Add Favorite") {
                        if label.isEmpty || label.isEmpty || favList.compactMap({ $0.path }).contains(path) {
                            Alertinator.shared.alert(title: "Invaild Favorite!", body: "Please make sure that you've typed in both the label and path fields, and that the path you put in is not the same as any paths currently added as favorites.")
                        } else {
                            favList.append(FavoriteItem(label: label, path: path))
                        }
                    }
                }
                
                Section {
                    ForEach(favList) { fav in
                        Button(action: {
                            let path = generateNavPath(path: fav.path)
                            navPath.append(URL(fileURLWithPath: path))
                            dismiss()
                        }) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(fav.label)
                                    Text(fav.path)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tertiary)
                                    .imageScale(.small)
                            }
                        }
                        .foregroundStyle(Color(.label))
                        .padding(.vertical, !isSolariumUI() ? 1 : 0)
                        .contextMenu {
                            Button(role: .destructive) {
                                favList.removeAll { $0.id == fav.id }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HeaderLabel(text: "Favorites", icon: "star")
                }
            }
            .navigationTitle("Favorites")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        CloseSheetLabel()
                    }
                    .contentShape(.rect)
                }
            }
        }
    }
}
