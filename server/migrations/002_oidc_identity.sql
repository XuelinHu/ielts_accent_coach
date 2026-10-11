ALTER TABLE app_user
    ALTER COLUMN installation_id DROP NOT NULL;

ALTER TABLE app_user
    ADD COLUMN oidc_subject TEXT;

CREATE UNIQUE INDEX idx_app_user_oidc_subject
    ON app_user (oidc_subject)
    WHERE oidc_subject IS NOT NULL;
