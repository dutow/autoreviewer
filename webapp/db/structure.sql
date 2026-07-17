CREATE TABLE "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE "review_versions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "project" varchar NOT NULL, "topic" varchar NOT NULL, "version" integer NOT NULL, "title" varchar, "source_url" varchar, "hackorum_url" varchar, "reviewed_at" datetime(6), "path" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_review_versions_on_project_and_topic_and_version" ON "review_versions" ("project", "topic", "version") /*application='Webapp'*/;
CREATE INDEX "index_review_versions_on_reviewed_at" ON "review_versions" ("reviewed_at") /*application='Webapp'*/;
CREATE TABLE "documents" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "review_version_id" integer NOT NULL, "relpath" varchar NOT NULL, "kind" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_5a393b88fe"
FOREIGN KEY ("review_version_id")
  REFERENCES "review_versions" ("id")
);
CREATE INDEX "index_documents_on_review_version_id" ON "documents" ("review_version_id") /*application='Webapp'*/;
CREATE UNIQUE INDEX "index_documents_on_review_version_id_and_relpath" ON "documents" ("review_version_id", "relpath") /*application='Webapp'*/;
CREATE TABLE "index_states" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "key" varchar NOT NULL, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE UNIQUE INDEX "index_index_states_on_key" ON "index_states" ("key") /*application='Webapp'*/;
CREATE VIRTUAL TABLE documents_fts USING fts5(content, tokenize = 'porter unicode61')
/* documents_fts(content) */;
INSERT INTO "schema_migrations" (version) VALUES
('20260703124001');

