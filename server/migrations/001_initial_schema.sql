CREATE TABLE app_user (
    id UUID PRIMARY KEY,
    installation_id VARCHAR(80) NOT NULL UNIQUE,
    display_name VARCHAR(80),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE user_setting (
    user_id UUID PRIMARY KEY REFERENCES app_user(id) ON DELETE CASCADE,
    preferred_accent VARCHAR(20) NOT NULL DEFAULT 'british'
        CHECK (preferred_accent IN ('british', 'american', 'australian')),
    daily_goal SMALLINT NOT NULL DEFAULT 5 CHECK (daily_goal BETWEEN 1 AND 50),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE app_session (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    device_model VARCHAR(160),
    app_version VARCHAR(40),
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_active_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_app_session_user_started
    ON app_session (user_id, started_at DESC);

CREATE TABLE practice_attempt (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    session_id UUID REFERENCES app_session(id) ON DELETE SET NULL,
    accent VARCHAR(20) NOT NULL
        CHECK (accent IN ('british', 'american', 'australian')),
    topic VARCHAR(120) NOT NULL,
    level VARCHAR(30) NOT NULL,
    reference_text TEXT NOT NULL,
    transcript_text TEXT NOT NULL,
    focus_text VARCHAR(160) NOT NULL,
    overall_score SMALLINT NOT NULL CHECK (overall_score BETWEEN 0 AND 100),
    accuracy_score SMALLINT NOT NULL CHECK (accuracy_score BETWEEN 0 AND 100),
    completeness_score SMALLINT NOT NULL CHECK (completeness_score BETWEEN 0 AND 100),
    fluency_score SMALLINT NOT NULL CHECK (fluency_score BETWEEN 0 AND 100),
    next_requirements JSONB NOT NULL DEFAULT '[]'::JSONB,
    recording_storage VARCHAR(30) NOT NULL DEFAULT 'local_device'
        CHECK (recording_storage = 'local_device'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_practice_attempt_user_created
    ON practice_attempt (user_id, created_at DESC);

CREATE TABLE ai_conversation (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    session_id UUID REFERENCES app_session(id) ON DELETE SET NULL,
    title VARCHAR(160) NOT NULL DEFAULT 'IELTS 口语教练',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ai_conversation_user_updated
    ON ai_conversation (user_id, updated_at DESC);

CREATE TABLE ai_message (
    id UUID PRIMARY KEY,
    conversation_id UUID NOT NULL REFERENCES ai_conversation(id) ON DELETE CASCADE,
    practice_attempt_id UUID REFERENCES practice_attempt(id) ON DELETE SET NULL,
    role VARCHAR(20) NOT NULL CHECK (role IN ('user', 'assistant')),
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ai_message_conversation_created
    ON ai_message (conversation_id, created_at ASC);

