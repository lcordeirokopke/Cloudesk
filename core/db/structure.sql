SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: conversation_state; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.conversation_state AS ENUM (
    'triage',
    'with_ai',
    'awaiting_human',
    'with_human',
    'resolved',
    'closed'
);


--
-- Name: audit_events_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.audit_events_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  RAISE EXCEPTION 'audit_events is append-only';
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: attendants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attendants (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    kind character varying NOT NULL,
    name character varying NOT NULL,
    team_id uuid,
    capacity integer NOT NULL,
    skills character varying[] DEFAULT '{}'::character varying[] NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT attendants_kind_check CHECK (((kind)::text = ANY ((ARRAY['ai'::character varying, 'human'::character varying])::text[])))
);

ALTER TABLE ONLY public.attendants FORCE ROW LEVEL SECURITY;


--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_events (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    event_id uuid DEFAULT uuidv7() NOT NULL,
    actor_type character varying NOT NULL,
    actor_id uuid,
    action character varying NOT NULL,
    target_type character varying NOT NULL,
    target_id uuid,
    conversation_id uuid,
    before jsonb,
    after jsonb,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    reason character varying,
    routing_rule_id uuid,
    rule_version integer,
    trace_id character varying,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.audit_events FORCE ROW LEVEL SECURITY;


--
-- Name: brands; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brands (
    id uuid DEFAULT uuidv7() NOT NULL,
    slug character varying NOT NULL,
    name character varying NOT NULL,
    locale character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: contact_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contact_identities (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    contact_id uuid NOT NULL,
    channel character varying NOT NULL,
    value character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT contact_identities_channel_check CHECK (((channel)::text = ANY ((ARRAY['chat'::character varying, 'whatsapp'::character varying, 'email'::character varying])::text[])))
);

ALTER TABLE ONLY public.contact_identities FORCE ROW LEVEL SECURITY;


--
-- Name: contacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contacts (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    name character varying NOT NULL,
    segment character varying,
    locale character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.contacts FORCE ROW LEVEL SECURITY;


--
-- Name: conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.conversations (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    contact_id uuid NOT NULL,
    channel character varying NOT NULL,
    state public.conversation_state DEFAULT 'triage'::public.conversation_state NOT NULL,
    queue_id uuid,
    attendant_id uuid,
    priority integer DEFAULT 0 NOT NULL,
    category character varying,
    last_sequence integer DEFAULT 0 NOT NULL,
    resolved_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT conversations_channel_check CHECK (((channel)::text = ANY ((ARRAY['chat'::character varying, 'whatsapp'::character varying, 'email'::character varying])::text[])))
);

ALTER TABLE ONLY public.conversations FORCE ROW LEVEL SECURITY;


--
-- Name: customer_memories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_memories (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    contact_id uuid NOT NULL,
    summary text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.customer_memories FORCE ROW LEVEL SECURITY;


--
-- Name: handoffs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.handoffs (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    reason character varying NOT NULL,
    summary text NOT NULL,
    context jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.handoffs FORCE ROW LEVEL SECURITY;


--
-- Name: messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.messages (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    sequence integer NOT NULL,
    channel character varying NOT NULL,
    author character varying NOT NULL,
    attendant_id uuid,
    body text NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT messages_author_check CHECK (((author)::text = ANY ((ARRAY['customer'::character varying, 'ai'::character varying, 'analyst'::character varying, 'system'::character varying])::text[]))),
    CONSTRAINT messages_channel_check CHECK (((channel)::text = ANY ((ARRAY['chat'::character varying, 'whatsapp'::character varying, 'email'::character varying])::text[])))
);

ALTER TABLE ONLY public.messages FORCE ROW LEVEL SECURITY;


--
-- Name: processed_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.processed_events (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    idempotency_key character varying NOT NULL,
    result jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.processed_events FORCE ROW LEVEL SECURITY;


--
-- Name: queues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.queues (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    name character varying NOT NULL,
    team_id uuid,
    sla_minutes integer NOT NULL,
    capacity integer NOT NULL,
    first_attendant character varying NOT NULL,
    overflow_queue_id uuid,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    CONSTRAINT queues_first_attendant_check CHECK (((first_attendant)::text = ANY ((ARRAY['ai'::character varying, 'human'::character varying])::text[])))
);

ALTER TABLE ONLY public.queues FORCE ROW LEVEL SECURITY;


--
-- Name: routing_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.routing_rules (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    rule_id uuid NOT NULL,
    version integer NOT NULL,
    name character varying NOT NULL,
    "position" integer NOT NULL,
    "when" jsonb DEFAULT '{}'::jsonb NOT NULL,
    "then" jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.routing_rules FORCE ROW LEVEL SECURITY;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: solid_cable_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_cable_messages (
    id bigint NOT NULL,
    channel bytea NOT NULL,
    payload bytea NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    channel_hash bigint NOT NULL
);


--
-- Name: solid_cable_messages_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_cable_messages_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_cable_messages_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_cable_messages_id_seq OWNED BY public.solid_cable_messages.id;


--
-- Name: solid_cache_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_cache_entries (
    id bigint NOT NULL,
    key bytea NOT NULL,
    value bytea NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    key_hash bigint NOT NULL,
    byte_size integer NOT NULL
);


--
-- Name: solid_cache_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_cache_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_cache_entries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_cache_entries_id_seq OWNED BY public.solid_cache_entries.id;


--
-- Name: solid_queue_batch_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_batch_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    batch_id bigint NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_batch_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_batch_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_batch_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_batch_executions_id_seq OWNED BY public.solid_queue_batch_executions.id;


--
-- Name: solid_queue_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_batches (
    id bigint NOT NULL,
    active_job_batch_id character varying,
    description character varying,
    on_finish text,
    on_success text,
    on_failure text,
    metadata text,
    total_jobs integer DEFAULT 0 NOT NULL,
    completed_jobs integer DEFAULT 0 NOT NULL,
    failed_jobs integer DEFAULT 0 NOT NULL,
    enqueued_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    failed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_batches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_batches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_batches_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_batches_id_seq OWNED BY public.solid_queue_batches.id;


--
-- Name: solid_queue_blocked_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_blocked_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    concurrency_key character varying NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_blocked_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_blocked_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_blocked_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_blocked_executions_id_seq OWNED BY public.solid_queue_blocked_executions.id;


--
-- Name: solid_queue_claimed_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_claimed_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    process_id bigint,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_claimed_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_claimed_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_claimed_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_claimed_executions_id_seq OWNED BY public.solid_queue_claimed_executions.id;


--
-- Name: solid_queue_failed_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_failed_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    error text,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_failed_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_failed_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_failed_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_failed_executions_id_seq OWNED BY public.solid_queue_failed_executions.id;


--
-- Name: solid_queue_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_jobs (
    id bigint NOT NULL,
    queue_name character varying NOT NULL,
    class_name character varying NOT NULL,
    arguments text,
    priority integer DEFAULT 0 NOT NULL,
    active_job_id character varying,
    scheduled_at timestamp(6) without time zone,
    finished_at timestamp(6) without time zone,
    concurrency_key character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    batch_id bigint
);


--
-- Name: solid_queue_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_jobs_id_seq OWNED BY public.solid_queue_jobs.id;


--
-- Name: solid_queue_pauses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_pauses (
    id bigint NOT NULL,
    queue_name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_pauses_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_pauses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_pauses_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_pauses_id_seq OWNED BY public.solid_queue_pauses.id;


--
-- Name: solid_queue_processes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_processes (
    id bigint NOT NULL,
    kind character varying NOT NULL,
    last_heartbeat_at timestamp(6) without time zone NOT NULL,
    supervisor_id bigint,
    pid integer NOT NULL,
    hostname character varying,
    metadata text,
    created_at timestamp(6) without time zone NOT NULL,
    name character varying NOT NULL
);


--
-- Name: solid_queue_processes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_processes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_processes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_processes_id_seq OWNED BY public.solid_queue_processes.id;


--
-- Name: solid_queue_ready_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_ready_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_ready_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_ready_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_ready_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_ready_executions_id_seq OWNED BY public.solid_queue_ready_executions.id;


--
-- Name: solid_queue_recurring_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_recurring_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    task_key character varying NOT NULL,
    run_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_recurring_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_recurring_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_recurring_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_recurring_executions_id_seq OWNED BY public.solid_queue_recurring_executions.id;


--
-- Name: solid_queue_recurring_tasks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_recurring_tasks (
    id bigint NOT NULL,
    key character varying NOT NULL,
    schedule character varying NOT NULL,
    command character varying(2048),
    class_name character varying,
    arguments text,
    queue_name character varying,
    priority integer DEFAULT 0,
    static boolean DEFAULT true NOT NULL,
    description text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_recurring_tasks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_recurring_tasks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_recurring_tasks_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_recurring_tasks_id_seq OWNED BY public.solid_queue_recurring_tasks.id;


--
-- Name: solid_queue_scheduled_executions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_scheduled_executions (
    id bigint NOT NULL,
    job_id bigint NOT NULL,
    queue_name character varying NOT NULL,
    priority integer DEFAULT 0 NOT NULL,
    scheduled_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_scheduled_executions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_scheduled_executions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_scheduled_executions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_scheduled_executions_id_seq OWNED BY public.solid_queue_scheduled_executions.id;


--
-- Name: solid_queue_semaphores; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.solid_queue_semaphores (
    id bigint NOT NULL,
    key character varying NOT NULL,
    value integer DEFAULT 1 NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: solid_queue_semaphores_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.solid_queue_semaphores_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: solid_queue_semaphores_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.solid_queue_semaphores_id_seq OWNED BY public.solid_queue_semaphores.id;


--
-- Name: teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.teams (
    id uuid DEFAULT uuidv7() NOT NULL,
    brand_id uuid NOT NULL,
    name character varying NOT NULL,
    skills character varying[] DEFAULT '{}'::character varying[] NOT NULL,
    business_hours jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);

ALTER TABLE ONLY public.teams FORCE ROW LEVEL SECURITY;


--
-- Name: solid_cable_messages id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cable_messages ALTER COLUMN id SET DEFAULT nextval('public.solid_cable_messages_id_seq'::regclass);


--
-- Name: solid_cache_entries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cache_entries ALTER COLUMN id SET DEFAULT nextval('public.solid_cache_entries_id_seq'::regclass);


--
-- Name: solid_queue_batch_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_batch_executions_id_seq'::regclass);


--
-- Name: solid_queue_batches id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batches ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_batches_id_seq'::regclass);


--
-- Name: solid_queue_blocked_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_blocked_executions_id_seq'::regclass);


--
-- Name: solid_queue_claimed_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_claimed_executions_id_seq'::regclass);


--
-- Name: solid_queue_failed_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_failed_executions_id_seq'::regclass);


--
-- Name: solid_queue_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_jobs ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_jobs_id_seq'::regclass);


--
-- Name: solid_queue_pauses id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_pauses ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_pauses_id_seq'::regclass);


--
-- Name: solid_queue_processes id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_processes ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_processes_id_seq'::regclass);


--
-- Name: solid_queue_ready_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_ready_executions_id_seq'::regclass);


--
-- Name: solid_queue_recurring_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_recurring_executions_id_seq'::regclass);


--
-- Name: solid_queue_recurring_tasks id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_tasks ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_recurring_tasks_id_seq'::regclass);


--
-- Name: solid_queue_scheduled_executions id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_scheduled_executions_id_seq'::regclass);


--
-- Name: solid_queue_semaphores id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_semaphores ALTER COLUMN id SET DEFAULT nextval('public.solid_queue_semaphores_id_seq'::regclass);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: attendants attendants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendants
    ADD CONSTRAINT attendants_pkey PRIMARY KEY (id);


--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: brands brands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_pkey PRIMARY KEY (id);


--
-- Name: contact_identities contact_identities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_identities
    ADD CONSTRAINT contact_identities_pkey PRIMARY KEY (id);


--
-- Name: contacts contacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT contacts_pkey PRIMARY KEY (id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: customer_memories customer_memories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_memories
    ADD CONSTRAINT customer_memories_pkey PRIMARY KEY (id);


--
-- Name: handoffs handoffs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.handoffs
    ADD CONSTRAINT handoffs_pkey PRIMARY KEY (id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: processed_events processed_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_events
    ADD CONSTRAINT processed_events_pkey PRIMARY KEY (id);


--
-- Name: queues queues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queues
    ADD CONSTRAINT queues_pkey PRIMARY KEY (id);


--
-- Name: routing_rules routing_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routing_rules
    ADD CONSTRAINT routing_rules_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: solid_cable_messages solid_cable_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cable_messages
    ADD CONSTRAINT solid_cable_messages_pkey PRIMARY KEY (id);


--
-- Name: solid_cache_entries solid_cache_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_cache_entries
    ADD CONSTRAINT solid_cache_entries_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_batch_executions solid_queue_batch_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions
    ADD CONSTRAINT solid_queue_batch_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_batches solid_queue_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batches
    ADD CONSTRAINT solid_queue_batches_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_blocked_executions solid_queue_blocked_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions
    ADD CONSTRAINT solid_queue_blocked_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_claimed_executions solid_queue_claimed_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions
    ADD CONSTRAINT solid_queue_claimed_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_failed_executions solid_queue_failed_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions
    ADD CONSTRAINT solid_queue_failed_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_jobs solid_queue_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_jobs
    ADD CONSTRAINT solid_queue_jobs_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_pauses solid_queue_pauses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_pauses
    ADD CONSTRAINT solid_queue_pauses_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_processes solid_queue_processes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_processes
    ADD CONSTRAINT solid_queue_processes_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_ready_executions solid_queue_ready_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions
    ADD CONSTRAINT solid_queue_ready_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_recurring_executions solid_queue_recurring_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions
    ADD CONSTRAINT solid_queue_recurring_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_recurring_tasks solid_queue_recurring_tasks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_tasks
    ADD CONSTRAINT solid_queue_recurring_tasks_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_scheduled_executions solid_queue_scheduled_executions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions
    ADD CONSTRAINT solid_queue_scheduled_executions_pkey PRIMARY KEY (id);


--
-- Name: solid_queue_semaphores solid_queue_semaphores_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_semaphores
    ADD CONSTRAINT solid_queue_semaphores_pkey PRIMARY KEY (id);


--
-- Name: teams teams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_pkey PRIMARY KEY (id);


--
-- Name: index_attendants_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_attendants_on_brand_id_and_id ON public.attendants USING btree (brand_id, id);


--
-- Name: index_attendants_on_brand_id_and_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_attendants_on_brand_id_and_team_id ON public.attendants USING btree (brand_id, team_id);


--
-- Name: index_audit_events_on_brand_id_and_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_brand_id_and_conversation_id ON public.audit_events USING btree (brand_id, conversation_id);


--
-- Name: index_audit_events_on_brand_id_and_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_audit_events_on_brand_id_and_event_id ON public.audit_events USING btree (brand_id, event_id);


--
-- Name: index_audit_events_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_audit_events_on_brand_id_and_id ON public.audit_events USING btree (brand_id, id);


--
-- Name: index_audit_events_on_brand_id_and_routing_rule_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_brand_id_and_routing_rule_id ON public.audit_events USING btree (brand_id, routing_rule_id);


--
-- Name: index_audit_events_on_brand_id_and_trace_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_audit_events_on_brand_id_and_trace_id ON public.audit_events USING btree (brand_id, trace_id);


--
-- Name: index_brands_on_slug; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_brands_on_slug ON public.brands USING btree (slug);


--
-- Name: index_contact_identities_on_brand_id_and_channel_and_value; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contact_identities_on_brand_id_and_channel_and_value ON public.contact_identities USING btree (brand_id, channel, value);


--
-- Name: index_contact_identities_on_brand_id_and_contact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_contact_identities_on_brand_id_and_contact_id ON public.contact_identities USING btree (brand_id, contact_id);


--
-- Name: index_contact_identities_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contact_identities_on_brand_id_and_id ON public.contact_identities USING btree (brand_id, id);


--
-- Name: index_contacts_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_contacts_on_brand_id_and_id ON public.contacts USING btree (brand_id, id);


--
-- Name: index_conversations_on_brand_id_and_attendant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_brand_id_and_attendant_id ON public.conversations USING btree (brand_id, attendant_id);


--
-- Name: index_conversations_on_brand_id_and_contact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_brand_id_and_contact_id ON public.conversations USING btree (brand_id, contact_id);


--
-- Name: index_conversations_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_conversations_on_brand_id_and_id ON public.conversations USING btree (brand_id, id);


--
-- Name: index_conversations_on_brand_id_and_queue_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_conversations_on_brand_id_and_queue_id ON public.conversations USING btree (brand_id, queue_id);


--
-- Name: index_customer_memories_on_brand_id_and_contact_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_customer_memories_on_brand_id_and_contact_id ON public.customer_memories USING btree (brand_id, contact_id);


--
-- Name: index_customer_memories_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_customer_memories_on_brand_id_and_id ON public.customer_memories USING btree (brand_id, id);


--
-- Name: index_handoffs_on_brand_id_and_conversation_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_handoffs_on_brand_id_and_conversation_id ON public.handoffs USING btree (brand_id, conversation_id);


--
-- Name: index_handoffs_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_handoffs_on_brand_id_and_id ON public.handoffs USING btree (brand_id, id);


--
-- Name: index_messages_on_brand_id_and_attendant_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_messages_on_brand_id_and_attendant_id ON public.messages USING btree (brand_id, attendant_id);


--
-- Name: index_messages_on_brand_id_and_conversation_id_and_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_messages_on_brand_id_and_conversation_id_and_sequence ON public.messages USING btree (brand_id, conversation_id, sequence);


--
-- Name: index_messages_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_messages_on_brand_id_and_id ON public.messages USING btree (brand_id, id);


--
-- Name: index_processed_events_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_processed_events_on_brand_id_and_id ON public.processed_events USING btree (brand_id, id);


--
-- Name: index_processed_events_on_brand_id_and_idempotency_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_processed_events_on_brand_id_and_idempotency_key ON public.processed_events USING btree (brand_id, idempotency_key);


--
-- Name: index_queues_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_queues_on_brand_id_and_id ON public.queues USING btree (brand_id, id);


--
-- Name: index_queues_on_brand_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_queues_on_brand_id_and_name ON public.queues USING btree (brand_id, name);


--
-- Name: index_queues_on_brand_id_and_overflow_queue_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_queues_on_brand_id_and_overflow_queue_id ON public.queues USING btree (brand_id, overflow_queue_id);


--
-- Name: index_queues_on_brand_id_and_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_queues_on_brand_id_and_team_id ON public.queues USING btree (brand_id, team_id);


--
-- Name: index_routing_rules_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_routing_rules_on_brand_id_and_id ON public.routing_rules USING btree (brand_id, id);


--
-- Name: index_routing_rules_on_brand_id_and_rule_id_and_version; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_routing_rules_on_brand_id_and_rule_id_and_version ON public.routing_rules USING btree (brand_id, rule_id, version);


--
-- Name: index_solid_cable_messages_on_channel_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cable_messages_on_channel_hash ON public.solid_cable_messages USING btree (channel_hash);


--
-- Name: index_solid_cable_messages_on_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cable_messages_on_created_at ON public.solid_cable_messages USING btree (created_at);


--
-- Name: index_solid_cache_entries_on_byte_size; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cache_entries_on_byte_size ON public.solid_cache_entries USING btree (byte_size);


--
-- Name: index_solid_cache_entries_on_key_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_cache_entries_on_key_hash ON public.solid_cache_entries USING btree (key_hash);


--
-- Name: index_solid_cache_entries_on_key_hash_and_byte_size; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_cache_entries_on_key_hash_and_byte_size ON public.solid_cache_entries USING btree (key_hash, byte_size);


--
-- Name: index_solid_queue_batch_executions_on_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_batch_executions_on_batch_id ON public.solid_queue_batch_executions USING btree (batch_id);


--
-- Name: index_solid_queue_batch_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_batch_executions_on_job_id ON public.solid_queue_batch_executions USING btree (job_id);


--
-- Name: index_solid_queue_batches_on_active_job_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_batches_on_active_job_batch_id ON public.solid_queue_batches USING btree (active_job_batch_id);


--
-- Name: index_solid_queue_batches_on_finished_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_batches_on_finished_at ON public.solid_queue_batches USING btree (finished_at);


--
-- Name: index_solid_queue_blocked_executions_for_maintenance; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_blocked_executions_for_maintenance ON public.solid_queue_blocked_executions USING btree (expires_at, concurrency_key);


--
-- Name: index_solid_queue_blocked_executions_for_release; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_blocked_executions_for_release ON public.solid_queue_blocked_executions USING btree (concurrency_key, priority, job_id);


--
-- Name: index_solid_queue_blocked_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_blocked_executions_on_job_id ON public.solid_queue_blocked_executions USING btree (job_id);


--
-- Name: index_solid_queue_claimed_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_claimed_executions_on_job_id ON public.solid_queue_claimed_executions USING btree (job_id);


--
-- Name: index_solid_queue_claimed_executions_on_process_id_and_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_claimed_executions_on_process_id_and_job_id ON public.solid_queue_claimed_executions USING btree (process_id, job_id);


--
-- Name: index_solid_queue_dispatch_all; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_dispatch_all ON public.solid_queue_scheduled_executions USING btree (scheduled_at, priority, job_id);


--
-- Name: index_solid_queue_failed_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_failed_executions_on_job_id ON public.solid_queue_failed_executions USING btree (job_id);


--
-- Name: index_solid_queue_jobs_for_alerting; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_for_alerting ON public.solid_queue_jobs USING btree (scheduled_at, finished_at);


--
-- Name: index_solid_queue_jobs_for_filtering; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_for_filtering ON public.solid_queue_jobs USING btree (queue_name, finished_at);


--
-- Name: index_solid_queue_jobs_on_active_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_active_job_id ON public.solid_queue_jobs USING btree (active_job_id);


--
-- Name: index_solid_queue_jobs_on_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_batch_id ON public.solid_queue_jobs USING btree (batch_id);


--
-- Name: index_solid_queue_jobs_on_class_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_class_name ON public.solid_queue_jobs USING btree (class_name);


--
-- Name: index_solid_queue_jobs_on_finished_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_jobs_on_finished_at ON public.solid_queue_jobs USING btree (finished_at);


--
-- Name: index_solid_queue_pauses_on_queue_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_pauses_on_queue_name ON public.solid_queue_pauses USING btree (queue_name);


--
-- Name: index_solid_queue_poll_all; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_poll_all ON public.solid_queue_ready_executions USING btree (priority, job_id);


--
-- Name: index_solid_queue_poll_by_queue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_poll_by_queue ON public.solid_queue_ready_executions USING btree (queue_name, priority, job_id);


--
-- Name: index_solid_queue_processes_on_last_heartbeat_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_processes_on_last_heartbeat_at ON public.solid_queue_processes USING btree (last_heartbeat_at);


--
-- Name: index_solid_queue_processes_on_name_and_supervisor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_processes_on_name_and_supervisor_id ON public.solid_queue_processes USING btree (name, supervisor_id);


--
-- Name: index_solid_queue_processes_on_supervisor_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_processes_on_supervisor_id ON public.solid_queue_processes USING btree (supervisor_id);


--
-- Name: index_solid_queue_ready_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_ready_executions_on_job_id ON public.solid_queue_ready_executions USING btree (job_id);


--
-- Name: index_solid_queue_recurring_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_executions_on_job_id ON public.solid_queue_recurring_executions USING btree (job_id);


--
-- Name: index_solid_queue_recurring_executions_on_task_key_and_run_at; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_executions_on_task_key_and_run_at ON public.solid_queue_recurring_executions USING btree (task_key, run_at);


--
-- Name: index_solid_queue_recurring_tasks_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_recurring_tasks_on_key ON public.solid_queue_recurring_tasks USING btree (key);


--
-- Name: index_solid_queue_recurring_tasks_on_static; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_recurring_tasks_on_static ON public.solid_queue_recurring_tasks USING btree (static);


--
-- Name: index_solid_queue_scheduled_executions_on_job_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_scheduled_executions_on_job_id ON public.solid_queue_scheduled_executions USING btree (job_id);


--
-- Name: index_solid_queue_semaphores_on_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_semaphores_on_expires_at ON public.solid_queue_semaphores USING btree (expires_at);


--
-- Name: index_solid_queue_semaphores_on_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_solid_queue_semaphores_on_key ON public.solid_queue_semaphores USING btree (key);


--
-- Name: index_solid_queue_semaphores_on_key_and_value; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_solid_queue_semaphores_on_key_and_value ON public.solid_queue_semaphores USING btree (key, value);


--
-- Name: index_teams_on_brand_id_and_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_teams_on_brand_id_and_id ON public.teams USING btree (brand_id, id);


--
-- Name: index_teams_on_brand_id_and_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_teams_on_brand_id_and_name ON public.teams USING btree (brand_id, name);


--
-- Name: audit_events audit_events_block_row_changes; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_events_block_row_changes BEFORE DELETE OR UPDATE ON public.audit_events FOR EACH ROW EXECUTE FUNCTION public.audit_events_append_only();


--
-- Name: audit_events audit_events_block_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER audit_events_block_truncate BEFORE TRUNCATE ON public.audit_events FOR EACH STATEMENT EXECUTE FUNCTION public.audit_events_append_only();


--
-- Name: contacts fk_rails_071d8fad1e; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contacts
    ADD CONSTRAINT fk_rails_071d8fad1e FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: customer_memories fk_rails_0e7469a4c4; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_memories
    ADD CONSTRAINT fk_rails_0e7469a4c4 FOREIGN KEY (brand_id, contact_id) REFERENCES public.contacts(brand_id, id);


--
-- Name: handoffs fk_rails_133ec65ade; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.handoffs
    ADD CONSTRAINT fk_rails_133ec65ade FOREIGN KEY (brand_id, conversation_id) REFERENCES public.conversations(brand_id, id);


--
-- Name: messages fk_rails_19770f78ed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_19770f78ed FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: queues fk_rails_2167254322; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queues
    ADD CONSTRAINT fk_rails_2167254322 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: solid_queue_recurring_executions fk_rails_318a5533ed; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_recurring_executions
    ADD CONSTRAINT fk_rails_318a5533ed FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: audit_events fk_rails_36ad402aaf; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_36ad402aaf FOREIGN KEY (brand_id, routing_rule_id) REFERENCES public.routing_rules(brand_id, id);


--
-- Name: solid_queue_failed_executions fk_rails_39bbc7a631; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_failed_executions
    ADD CONSTRAINT fk_rails_39bbc7a631 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: contact_identities fk_rails_40970ab646; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_identities
    ADD CONSTRAINT fk_rails_40970ab646 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: handoffs fk_rails_411d2edb38; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.handoffs
    ADD CONSTRAINT fk_rails_411d2edb38 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: solid_queue_blocked_executions fk_rails_4cd34e2228; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_blocked_executions
    ADD CONSTRAINT fk_rails_4cd34e2228 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: audit_events fk_rails_4e04c336f8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_4e04c336f8 FOREIGN KEY (brand_id, conversation_id) REFERENCES public.conversations(brand_id, id);


--
-- Name: queues fk_rails_518a2f6688; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queues
    ADD CONSTRAINT fk_rails_518a2f6688 FOREIGN KEY (brand_id, team_id) REFERENCES public.teams(brand_id, id);


--
-- Name: teams fk_rails_5545c98c48; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT fk_rails_5545c98c48 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: messages fk_rails_5617fe4c83; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_5617fe4c83 FOREIGN KEY (brand_id, conversation_id) REFERENCES public.conversations(brand_id, id);


--
-- Name: attendants fk_rails_6b0d5f464b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendants
    ADD CONSTRAINT fk_rails_6b0d5f464b FOREIGN KEY (brand_id, team_id) REFERENCES public.teams(brand_id, id);


--
-- Name: routing_rules fk_rails_6d37313414; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.routing_rules
    ADD CONSTRAINT fk_rails_6d37313414 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: conversations fk_rails_763339c745; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT fk_rails_763339c745 FOREIGN KEY (brand_id, queue_id) REFERENCES public.queues(brand_id, id);


--
-- Name: solid_queue_batch_executions fk_rails_7c5e073422; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions
    ADD CONSTRAINT fk_rails_7c5e073422 FOREIGN KEY (batch_id) REFERENCES public.solid_queue_batches(id) ON DELETE CASCADE;


--
-- Name: solid_queue_ready_executions fk_rails_81fcbd66af; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_ready_executions
    ADD CONSTRAINT fk_rails_81fcbd66af FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: contact_identities fk_rails_8b672ddc5b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_identities
    ADD CONSTRAINT fk_rails_8b672ddc5b FOREIGN KEY (brand_id, contact_id) REFERENCES public.contacts(brand_id, id);


--
-- Name: solid_queue_claimed_executions fk_rails_9cfe4d4944; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_claimed_executions
    ADD CONSTRAINT fk_rails_9cfe4d4944 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: conversations fk_rails_a439201cd0; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT fk_rails_a439201cd0 FOREIGN KEY (brand_id, contact_id) REFERENCES public.contacts(brand_id, id);


--
-- Name: processed_events fk_rails_a6fae44238; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_events
    ADD CONSTRAINT fk_rails_a6fae44238 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: audit_events fk_rails_b7193bfed1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT fk_rails_b7193bfed1 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: solid_queue_batch_executions fk_rails_bc9f981155; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_batch_executions
    ADD CONSTRAINT fk_rails_bc9f981155 FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: solid_queue_scheduled_executions fk_rails_c4316f352d; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.solid_queue_scheduled_executions
    ADD CONSTRAINT fk_rails_c4316f352d FOREIGN KEY (job_id) REFERENCES public.solid_queue_jobs(id) ON DELETE CASCADE;


--
-- Name: customer_memories fk_rails_cbd8732d9a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_memories
    ADD CONSTRAINT fk_rails_cbd8732d9a FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: attendants fk_rails_cbef9a0b3a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attendants
    ADD CONSTRAINT fk_rails_cbef9a0b3a FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: queues fk_rails_cd61a0592f; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.queues
    ADD CONSTRAINT fk_rails_cd61a0592f FOREIGN KEY (brand_id, overflow_queue_id) REFERENCES public.queues(brand_id, id);


--
-- Name: conversations fk_rails_cfb3df345a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT fk_rails_cfb3df345a FOREIGN KEY (brand_id, attendant_id) REFERENCES public.attendants(brand_id, id);


--
-- Name: messages fk_rails_d6e9406403; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.messages
    ADD CONSTRAINT fk_rails_d6e9406403 FOREIGN KEY (brand_id, attendant_id) REFERENCES public.attendants(brand_id, id);


--
-- Name: conversations fk_rails_ea7ddca319; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.conversations
    ADD CONSTRAINT fk_rails_ea7ddca319 FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: attendants; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.attendants ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;

--
-- Name: attendants brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.attendants USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: audit_events brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.audit_events USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: contact_identities brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.contact_identities USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: contacts brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.contacts USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: conversations brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.conversations USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: customer_memories brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.customer_memories USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: handoffs brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.handoffs USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: messages brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.messages USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: processed_events brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.processed_events USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: queues brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.queues USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: routing_rules brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.routing_rules USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: teams brand_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brand_isolation ON public.teams USING ((brand_id = (NULLIF(current_setting('app.brand_id'::text, true), ''::text))::uuid));


--
-- Name: contact_identities; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contact_identities ENABLE ROW LEVEL SECURITY;

--
-- Name: contacts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.contacts ENABLE ROW LEVEL SECURITY;

--
-- Name: conversations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;

--
-- Name: customer_memories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_memories ENABLE ROW LEVEL SECURITY;

--
-- Name: handoffs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.handoffs ENABLE ROW LEVEL SECURITY;

--
-- Name: messages; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

--
-- Name: processed_events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.processed_events ENABLE ROW LEVEL SECURITY;

--
-- Name: queues; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.queues ENABLE ROW LEVEL SECURITY;

--
-- Name: routing_rules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.routing_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: teams; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.teams ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20261115130000'),
('20261115120000');


GRANT SELECT ON TABLE public.ar_internal_metadata TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.attendants TO cloudesk_app;
GRANT SELECT,INSERT ON TABLE public.audit_events TO cloudesk_app;
GRANT SELECT ON TABLE public.brands TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contact_identities TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.contacts TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.conversations TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.customer_memories TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.handoffs TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.messages TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.processed_events TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.queues TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.routing_rules TO cloudesk_app;
GRANT SELECT ON TABLE public.schema_migrations TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_cable_messages TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_cable_messages_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_cache_entries TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_cache_entries_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_batch_executions TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_batch_executions_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_batches TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_batches_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_blocked_executions TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_blocked_executions_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_claimed_executions TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_claimed_executions_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_failed_executions TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_failed_executions_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_jobs TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_jobs_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_pauses TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_pauses_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_processes TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_processes_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_ready_executions TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_ready_executions_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_recurring_executions TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_recurring_executions_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_recurring_tasks TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_recurring_tasks_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_scheduled_executions TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_scheduled_executions_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.solid_queue_semaphores TO cloudesk_app;
GRANT SELECT,USAGE ON SEQUENCE public.solid_queue_semaphores_id_seq TO cloudesk_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.teams TO cloudesk_app;
