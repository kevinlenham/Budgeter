//
//  ExportView.swift
//  Budgeter
//
//  DEC-002's other half, finally built.
//
//  DEC-002 chose durability over sync on the grounds that "durability on iOS is
//  nearly free: the SQLite file in Application Support is included in encrypted
//  device backup automatically, plus an explicit JSON/CSV export" — and then says
//  the quiet part out loud: "durability requires the export feature to actually be
//  built, not assumed." Until this screen shipped, the no-sync decision was unbacked
//  and there was one copy of the data and a hope.
//
//  Two files, two jobs (see `BackupExporter`): the JSON is the backup and is the
//  only one that can be restored; the CSV is for a spreadsheet and is deliberately
//  lossy. Both are written into the temporary directory and handed to the system
//  share sheet, so the app never needs anywhere to put them and iOS cleans up after
//  itself.
//

import GRDB
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    let database: AppDatabase

    @State private var jsonFile: URL?
    @State private var csvFile: URL?
    @State private var isImporting = false
    @State private var message: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if let jsonFile {
                    ShareLink(item: jsonFile) {
                        Label("Export backup (JSON)", systemImage: "square.and.arrow.up")
                    }
                } else {
                    ProgressView()
                }
                if let csvFile {
                    ShareLink(item: csvFile) {
                        Label("Export transactions (CSV)", systemImage: "tablecells")
                    }
                }
            } header: {
                Text("Export")
            } footer: {
                Text("The JSON backup holds everything — accounts, categories, limits, "
                    + "periods and every transaction — and is what Budgeter can read back. "
                    + "The CSV is a plain list of transactions for a spreadsheet.")
            }

            Section {
                Button {
                    isImporting = true
                } label: {
                    Label("Restore from a backup", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("Adds anything the backup has that this device does not. Nothing is "
                    + "overwritten and nothing is duplicated, so restoring the same file "
                    + "twice does nothing the second time.")
            }

            if let message {
                Section { Text(message) }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Your data")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            restore(from: result)
        }
        .task { await prepareFiles() }
    }

    // MARK: - Actions

    /// Writes both files up front so the share sheet has something to hand over the
    /// moment it is tapped. A `ShareLink` wants a URL that already exists, and a
    /// button that generates one first would put a spinner between the tap and the
    /// sheet for no reason — the whole database is small enough that this is quick.
    private func prepareFiles() async {
        do {
            let stamp = CivilDate.today().iso
            let exporter = BackupExporter()
            let (json, csv) = try await database.writer.read { db in
                (try exporter.json(from: db), try exporter.csv(from: db))
            }
            jsonFile = try write(json, to: "Budgeter-\(stamp).json")
            csvFile = try write(Data(csv.utf8), to: "Budgeter-\(stamp).csv")
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func write(_ data: Data, to name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func restore(from result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            // A file picked from Files or iCloud Drive lives outside the app's
            // sandbox, and reading it without this returns a permissions error that
            // looks like a corrupt backup.
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            Task {
                do {
                    let report = try await database.writer.write { db in
                        try BackupImporter().restore(from: data, into: db)
                    }
                    message = summary(of: report)
                    errorMessage = nil
                    // The files on screen are now stale — they describe the database
                    // as it was before the restore.
                    await prepareFiles()
                } catch {
                    errorMessage = String(describing: error)
                }
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// DEC-005's skip report, in the shape the roadmap asks for: "12 imported, 3
    /// previously deleted and skipped". Saying how many rows were already there is
    /// what makes a second import visibly a no-op rather than apparently a failure.
    private func summary(of report: BackupImportReport) -> String {
        let restored = report.totalInserted
        guard restored > 0 || report.alreadyPresent > 0 else {
            return "Nothing to restore — that backup is empty."
        }
        return "\(restored) restored, \(report.alreadyPresent) already here."
    }
}
