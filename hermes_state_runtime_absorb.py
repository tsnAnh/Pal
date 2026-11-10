_PERSISTED_IN_TRANSCRIPT = (
    "SELECT 1 FROM (SELECT display_metadata FROM messages WHERE role='user' AND display_kind='steer' "
    "AND json_valid(display_metadata)) AS m, json_each(m.display_metadata, '$.admission_ids') AS j "
    "WHERE j.value=? LIMIT 1"
)


BOT_CHAT_TITLE = "Bot Chat"


def settle_lost_transfers(conn, *, epoch: int, steering: str) -> None:
    lost = conn.execute("SELECT a.admission_id, s.title FROM session_admissions a LEFT JOIN sessions s ON s.id=a.target_session_id "
                        "WHERE a.status='terminal' AND a.outcome=? AND a.owner_epoch!=?", (steering, epoch)).fetchall()
    for admission_id, title in lost:
        if title != BOT_CHAT_TITLE or conn.execute(_PERSISTED_IN_TRANSCRIPT, (admission_id,)).fetchone() is not None:
            conn.execute("UPDATE session_admissions SET outcome='interrupted' WHERE admission_id=?", (admission_id,))
        else:
            conn.execute("UPDATE session_admissions SET status='queued',outcome=NULL,generation=NULL "
                         "WHERE admission_id=?", (admission_id,))
