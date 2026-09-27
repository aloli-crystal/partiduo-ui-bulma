# SPDX-License-Identifier: AGPL-3.0-or-later

module PartiduoUi
  module SpecSupport
    # Schéma de la base de test construit *par les migrations* du cœur
    # (DECISIONS D-UI-028, révise D-016) : les écritures du lot 2 s'appuient
    # sur les contraintes et déclencheurs que les migrations posent en SQL
    # (équilibre différé, périodes closes, numérotation des factures), absents
    # d'un schéma synchronisé depuis les modèles.
    def self.migrate_fresh! : Nil
      connection = Marten::DB::Connection.default
      name = Marten.settings.databases.first.name.to_s
      raise "Base de test refusée : « #{name} » ne contient pas « test » (voir DATABASE_URL)." unless name.includes?("test")
      connection.open do |db|
        db.exec("DROP SCHEMA public CASCADE")
        db.exec("CREATE SCHEMA public")
      end
      Marten::DB::Management::Migrations::Runner.new(connection).execute
    end
  end
end

# Enregistré après celui de `marten/spec` (synchronisation des modèles) : on
# repart d'un schéma vide et on applique les migrations.
Spec.before_suite { PartiduoUi::SpecSupport.migrate_fresh! }
