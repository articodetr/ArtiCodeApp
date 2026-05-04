
-- Optional cleanup: keep only one pending approval_needed notification per user + movement.
with ranked as (
  select
    id,
    row_number() over (
      partition by user_id, movement_id, lower(coalesce(status, ''))
      order by
        case when action_required = false then 0 else 1 end,
        created_at desc
    ) as rn
  from movement_notifications
  where deleted_at is null
    and movement_id is not null
    and notification_type = 'approval_needed'
    and lower(coalesce(status, '')) = 'pending'
)
delete from movement_notifications mn
using ranked r
where mn.id = r.id
  and r.rn > 1;
