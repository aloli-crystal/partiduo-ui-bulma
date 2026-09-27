# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private NNBSP = " "

private def with_locale(locale : String, &)
  previous = I18n.locale
  I18n.activate(locale)
  yield
ensure
  I18n.activate(previous || "fr")
end

describe PartiduoUi::Format do
  it "formate les montants selon la langue et le pays, sans passer par Float" do
    value = BigDecimal.new("1234567.505")
    PartiduoUi::Format.new("fr", "FR").amount(value).should eq("1#{NNBSP}234#{NNBSP}567,51")
    PartiduoUi::Format.new("fr", "BE").amount(value).should eq("1#{NNBSP}234#{NNBSP}567,51")
    PartiduoUi::Format.new("nl", "BE").amount(value).should eq("1.234.567,51")
    PartiduoUi::Format.new("en", "").amount(value).should eq("1,234,567.51")
    PartiduoUi::Format.new("en", "BE").amount(value).should eq("1.234.567,51")
    PartiduoUi::Format.new("en", "FR").amount(value).should eq("1#{NNBSP}234#{NNBSP}567,51")
    PartiduoUi::Format.new("fr", "FR").amount(BigDecimal.new("-0.5")).should eq("-0,50")
    PartiduoUi::Format.new("fr", "FR").amount(BigDecimal.new("-0.001")).should eq("0,00")
    PartiduoUi::Format.new("fr", "FR").amount(BigDecimal.new("999")).should eq("999,00")
    PartiduoUi::Format.new("fr", "FR").amount(BigDecimal.new("12.5"), 4).should eq("12,5000")
    PartiduoUi::Format.new("fr", "FR").amount(nil).should eq("")
    PartiduoUi::Format.new("fr", "FR").amount(BigDecimal.new("1000"), group: false).should eq("1000,00")
  end

  it "formate les taux sans zéros inutiles" do
    PartiduoUi::Format.new("fr", "FR").percent(BigDecimal.new("5.5000")).should eq("5,5#{NNBSP}%")
    PartiduoUi::Format.new("fr", "FR").percent(BigDecimal.new("20.0000")).should eq("20#{NNBSP}%")
    PartiduoUi::Format.new("en", "").percent(BigDecimal.new("2.1")).should eq("2.1%")
    PartiduoUi::Format.new("nl", "BE").number(BigDecimal.new("21")).should eq("21")
  end

  it "formate les dates selon la langue et le pays" do
    day = Time.utc(2026, 9, 7)
    PartiduoUi::Format.new("fr", "FR").date(day).should eq("07/09/2026")
    PartiduoUi::Format.new("nl", "NL").date(day).should eq("07-09-2026")
    PartiduoUi::Format.new("nl", "BE").date(day).should eq("07/09/2026")
    PartiduoUi::Format.new("en", "US").date(day).should eq("09/07/2026")
    PartiduoUi::Format.new("en", "BE").date(day).should eq("07/09/2026")
    PartiduoUi::Format.new("fr", "FR").date(nil).should eq("")
  end

  it "nomme les périodes mensuelles dans la langue de l'utilisateur" do
    with_locale("fr") do
      format = PartiduoUi::Format.new("fr", "FR")
      format.period(Time.utc(2026, 9, 1), Time.utc(2026, 9, 30)).should eq("septembre 2026")
      format.period(Time.utc(2026, 12, 31), Time.utc(2026, 12, 31)).should eq("31/12/2026")
      format.period(Time.utc(2026, 9, 15), Time.utc(2026, 10, 14)).should eq("15/09/2026 – 14/10/2026")
    end
    with_locale("nl") do
      PartiduoUi::Format.new("nl", "BE").period(Time.utc(2026, 2, 1), Time.utc(2026, 2, 28)).should eq("februari 2026")
    end
  end

  it "lit les nombres saisis dans les écritures usuelles" do
    {
      "1 234,56" => "1234.56", "1.234,56" => "1234.56", "1,234.56" => "1234.56", "1234.5" => "1234.5",
      "12" => "12", "-3,5" => "-3.5", "1#{NNBSP}000" => "1000", ",5" => "0.5",
    }.each do |text, expected|
      PartiduoUi::Format.parse_decimal(text).should eq(BigDecimal.new(expected))
    end
    PartiduoUi::Format.parse_decimal("douze").should be_nil
    PartiduoUi::Format.parse_decimal("").should be_nil
    PartiduoUi::Format.parse_decimal("1e5").should be_nil
  end

  it "lit les dates du navigateur et celles de la langue" do
    format = PartiduoUi::Format.new("fr", "FR")
    format.parse_date("2026-09-07").should eq(Time.utc(2026, 9, 7))
    format.parse_date("07/09/2026").should eq(Time.utc(2026, 9, 7))
    format.parse_date("2026-13-01").should be_nil
    format.parse_date("").should be_nil
  end

  it "exporte en CSV avec le séparateur des tableurs de la langue" do
    PartiduoUi::Format.new("fr", "FR").csv_separator.should eq(';')
    PartiduoUi::Format.new("en", "").csv_separator.should eq(',')
    PartiduoUi::Format.new("fr", "FR").csv_amount(BigDecimal.new("1234.5")).should eq("1234,50")
  end
end

describe PartiduoUi::Table do
  columns = [
    PartiduoUi::Table::Column.new("name", "Nom"),
    PartiduoUi::Table::Column.new("amount", "Montant", "amount"),
    PartiduoUi::Table::Column.new("actions", "Actions", "actions"),
  ]
  build = ->(names : Array(String)) do
    rows = names.map_with_index do |name, index|
      PartiduoUi::Table::Row.new([
        PartiduoUi::Table::Cell.new(name),
        PartiduoUi::Table::Cell.new("#{index * 10},00", sort: BigDecimal.new(index * 10), csv: "#{index * 10},00"),
        PartiduoUi::Table::Cell.new(""),
      ])
    end
    PartiduoUi::Table.new("Essai", columns, rows, "/essai")
  end

  it "trie par colonne, dans les deux sens, les nombres comme des nombres" do
    table = build.call(["Élodie", "adam", "Zoé"]).sort!("name")
    table.rows.map(&.cells.first.text).should eq(["adam", "Élodie", "Zoé"])
    table = build.call(["b", "a", "c"]).sort!("-amount")
    table.rows.map(&.cells.first.text).should eq(["c", "a", "b"])
    table.headers[1].aria_sort.should eq("descending")
    table.headers[0].url.should eq("/essai?sort=name")
    table.headers[2].url.should be_nil
    build.call(["b", "a"]).sort!("inconnue").rows.map(&.cells.first.text).should eq(["b", "a"])
  end

  it "filtre sans tenir compte de la casse ni des accents" do
    table = build.call(["Élodie", "adam", "Zoé"]).filter!("ELO")
    table.rows.map(&.cells.first.text).should eq(["Élodie"])
    table.total.should eq(1)
    table.url.should eq("/essai?q=ELO")
  end

  it "découpe en pages et garde les paramètres dans les liens" do
    table = build.call((1..5).map { |index| "n#{index}" }).filter!("n").sort!("name").paginate!(2, per_page: 2)
    table.rows.map(&.cells.first.text).should eq(["n3", "n4"])
    table.page_count.should eq(3)
    pages = table.pages || [] of PartiduoUi::Table::PageLink
    pages.map(&.url).should eq(["/essai?q=n&sort=name", "/essai?q=n&sort=name&page=2", "/essai?q=n&sort=name&page=3"])
    pages[1].current.should be_true
    table.csv_url.should eq("/essai?q=n&sort=name&format=csv")
  end

  it "exporte en CSV les colonnes de données, en-tête compris" do
    csv = build.call(["a;b", "c"]).to_csv(PartiduoUi::Format.new("fr", "FR"))
    csv.should start_with("﻿")
    csv.lchop("﻿").should eq(%(Nom;Montant\n"a;b";0,00\nc;10,00\n))
  end
end
