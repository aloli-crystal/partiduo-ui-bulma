# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  # Tableaux d'un écran traduits pour le service neutre du cœur
  # `Partiduo::Api::Core.table_pdf` (BLOCAGES B-CRIT-001, DECISIONS
  # D-R5-008) : textes affichés (déjà mis en forme selon la langue),
  # étiquettes ajoutées au texte, colonnes d'actions écartées, lignes de pied
  # en total ; plusieurs tableaux se suivent, chacun sous son titre.
  module TablePdf
    alias Core = Partiduo::Api::Core

    WEIGHTS = {"mono" => 1.0, "amount" => 1.1, "text" => 2.0}

    def self.input(tables : Array({String?, Table}), title : String, name : String,
                   subtitle : Array(String) = [] of String) : Core::TableInput
      first = tables.first?.try(&.[1])
      kept = first ? exported(first) : [] of Int32
      columns = first ? kept.map { |index| column(first.columns[index]) } : [Core::TableColumnInput.new(title)]
      rows = [] of Core::TableRowInput
      tables.each do |(heading, table)|
        indices = exported(table)
        if tables.size > 1 && heading
          rows << Core::TableRowInput.new([heading], "heading")
        end
        if table.columns.size != first.try(&.columns.size)
          rows << Core::TableRowInput.new(indices.map { |index| table.columns[index].label }[0, columns.size], "heading")
        end
        table.rows.each { |row| rows << row_input(row, indices, columns.size, "line") }
        table.footer_rows.try(&.each { |row| rows << row_input(row, indices, columns.size, "total") })
      end
      Core::TableInput.new(name: name, title: title, columns: columns, rows: rows, subtitle: subtitle)
    end

    # Colonnes exportées : toutes sauf les boutons d'actions.
    private def self.exported(table : Table) : Array(Int32)
      table.columns.each_index.select { |index| table.columns[index].kind != "actions" }.to_a
    end

    private def self.column(column : Table::Column) : Core::TableColumnInput
      kind = column.kind == "amount" ? "amount" : "text"
      Core::TableColumnInput.new(column.label, kind, WEIGHTS[column.kind]? || 1.5)
    end

    private def self.row_input(row : Table::Row, indices : Array(Int32), width : Int32, style : String) : Core::TableRowInput
      style = "total" if row.css.includes?("pd-row-total")
      cells = indices.compact_map do |index|
        cell = row.cells[index]? || next
        [cell.text, cell.tag].compact.reject(&.empty?).join(" · ")
      end
      Core::TableRowInput.new(cells[0, width], style)
    end
  end
end
