begin;

create or replace function public.ensure_creator_pending_movement_notification()
returns trigger
language plpgsql
as $$
declare
  v_creator_user_id uuid;
  v_customer_name text;
  v_actor_name text;
  v_status text;
  v_is_pending boolean;
  v_pending_message text;
  v_final_title text;
  v_final_message text;
begin
  v_creator_user_id := coalesce(new.created_by_user_id, new.source_user_id);

  if v_creator_user_id is null then
    return new;
  end if;

  select c.name
    into v_customer_name
  from public.customers c
  where c.id = new.customer_id;

  v_actor_name := nullif(trim(coalesce(new.created_by_user_name, '')), '');
  if v_actor_name is null then
    v_actor_name := v_customer_name;
  end if;

  v_status := lower(
    coalesce(
      nullif(trim(coalesce(new.approval_status::text, '')), ''),
      case when coalesce(new.pending_approval, false) then 'pending' else '' end
    )
  );

  v_is_pending := coalesce(new.pending_approval, false) or v_status = 'pending';

  v_pending_message := case
    when coalesce(v_customer_name, '') <> '' then
      format('تم إرسال هذه الحركة إلى %s وهي بانتظار الموافقة قبل دخولها في الإجماليات.', v_customer_name)
    else
      'تم إرسال هذه الحركة وهي بانتظار موافقة الطرف الآخر قبل دخولها في الإجماليات.'
  end;

  if v_is_pending then
    update public.movement_notifications
       set status = 'pending',
           title = 'عملية معلقة',
           message = v_pending_message,
           action_required = false,
           recipient_user_id = v_creator_user_id,
           sender_user_id = coalesce(new.source_user_id, new.created_by_user_id, v_creator_user_id),
           customer_id = new.customer_id,
           movement_number = new.movement_number,
           amount = new.amount,
           currency = new.currency,
           movement_type = new.movement_type,
           customer_name = v_customer_name,
           actor_name = v_actor_name,
           deleted_at = null,
           extra_data = coalesce(extra_data, '{}'::jsonb) || jsonb_strip_nulls(
             jsonb_build_object(
               'approval_status', 'pending',
               'created_by_user_id', v_creator_user_id,
               'source_user_id', coalesce(new.source_user_id, new.created_by_user_id),
               'created_by_name', new.created_by_user_name,
               'creator_user_name', new.created_by_user_name,
               'customer_name', v_customer_name,
               'note', new.notes
             )
           )
     where movement_id = new.id
       and user_id = v_creator_user_id
       and notification_type = 'approval_needed'
       and coalesce(action_required, false) = false;

    if not found then
      insert into public.movement_notifications (
        user_id,
        recipient_user_id,
        sender_user_id,
        customer_id,
        movement_id,
        notification_type,
        title,
        message,
        is_read,
        status,
        action_required,
        created_at,
        movement_number,
        amount,
        currency,
        movement_type,
        customer_name,
        actor_name,
        extra_data
      )
      values (
        v_creator_user_id,
        v_creator_user_id,
        coalesce(new.source_user_id, new.created_by_user_id, v_creator_user_id),
        new.customer_id,
        new.id,
        'approval_needed',
        'عملية معلقة',
        v_pending_message,
        false,
        'pending',
        false,
        now(),
        new.movement_number,
        new.amount,
        new.currency,
        new.movement_type,
        v_customer_name,
        v_actor_name,
        jsonb_strip_nulls(
          jsonb_build_object(
            'approval_status', 'pending',
            'created_by_user_id', v_creator_user_id,
            'source_user_id', coalesce(new.source_user_id, new.created_by_user_id),
            'created_by_name', new.created_by_user_name,
            'creator_user_name', new.created_by_user_name,
            'customer_name', v_customer_name,
            'note', new.notes
          )
        )
      );
    end if;
  elsif v_status in ('approved', 'rejected', 'done') then
    v_final_title := case
      when v_status = 'approved' then 'تمت الموافقة على الحركة'
      when v_status = 'rejected' then 'تم رفض الحركة'
      else 'تم تحديث الحركة'
    end;

    v_final_message := case
      when v_status = 'approved' and coalesce(v_customer_name, '') <> '' then format('وافق %s على هذه الحركة.', v_customer_name)
      when v_status = 'approved' then 'تمت الموافقة على هذه الحركة.'
      when v_status = 'rejected' and coalesce(v_customer_name, '') <> '' then format('رفض %s هذه الحركة.', v_customer_name)
      when v_status = 'rejected' then 'تم رفض هذه الحركة.'
      else 'تم تحديث حالة هذه الحركة.'
    end;

    update public.movement_notifications
       set status = v_status,
           title = v_final_title,
           message = v_final_message,
           action_required = false,
           acted_at = coalesce(acted_at, now()),
           recipient_user_id = v_creator_user_id,
           sender_user_id = coalesce(new.source_user_id, new.created_by_user_id, v_creator_user_id),
           customer_id = new.customer_id,
           movement_number = new.movement_number,
           amount = new.amount,
           currency = new.currency,
           movement_type = new.movement_type,
           customer_name = v_customer_name,
           actor_name = v_actor_name,
           extra_data = coalesce(extra_data, '{}'::jsonb) || jsonb_strip_nulls(
             jsonb_build_object(
               'approval_status', v_status,
               'reject_reason', new.reject_reason,
               'reason', new.reject_reason
             )
           )
     where movement_id = new.id
       and user_id = v_creator_user_id
       and notification_type = 'approval_needed'
       and coalesce(action_required, false) = false;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_ensure_creator_pending_movement_notification on public.account_movements;

create trigger trg_ensure_creator_pending_movement_notification
after insert or update of approval_status, pending_approval, reject_reason
on public.account_movements
for each row
execute function public.ensure_creator_pending_movement_notification();

with pending_rows as (
  select
    am.id as movement_id,
    coalesce(am.created_by_user_id, am.source_user_id) as creator_user_id,
    am.customer_id,
    am.movement_number,
    am.amount,
    am.currency,
    am.movement_type,
    am.notes,
    nullif(trim(coalesce(am.created_by_user_name, '')), '') as actor_name,
    c.name as customer_name,
    coalesce(am.source_user_id, am.created_by_user_id) as sender_user_id
  from public.account_movements am
  left join public.customers c
    on c.id = am.customer_id
  where (
      coalesce(am.pending_approval, false) = true
      or lower(coalesce(am.approval_status::text, '')) = 'pending'
    )
    and coalesce(am.created_by_user_id, am.source_user_id) is not null
)
insert into public.movement_notifications (
  user_id,
  recipient_user_id,
  sender_user_id,
  customer_id,
  movement_id,
  notification_type,
  title,
  message,
  is_read,
  status,
  action_required,
  created_at,
  movement_number,
  amount,
  currency,
  movement_type,
  customer_name,
  actor_name,
  extra_data
)
select
  p.creator_user_id,
  p.creator_user_id,
  p.sender_user_id,
  p.customer_id,
  p.movement_id,
  'approval_needed',
  'عملية معلقة',
  case
    when coalesce(p.customer_name, '') <> '' then format('تم إرسال هذه الحركة إلى %s وهي بانتظار الموافقة قبل دخولها في الإجماليات.', p.customer_name)
    else 'تم إرسال هذه الحركة وهي بانتظار موافقة الطرف الآخر قبل دخولها في الإجماليات.'
  end,
  false,
  'pending',
  false,
  now(),
  p.movement_number,
  p.amount,
  p.currency,
  p.movement_type,
  p.customer_name,
  coalesce(p.actor_name, p.customer_name),
  jsonb_strip_nulls(
    jsonb_build_object(
      'approval_status', 'pending',
      'created_by_user_id', p.creator_user_id,
      'source_user_id', p.sender_user_id,
      'created_by_name', p.actor_name,
      'creator_user_name', p.actor_name,
      'customer_name', p.customer_name,
      'note', p.notes
    )
  )
from pending_rows p
where not exists (
  select 1
  from public.movement_notifications mn
  where mn.movement_id = p.movement_id
    and mn.user_id = p.creator_user_id
    and mn.notification_type = 'approval_needed'
    and coalesce(mn.action_required, false) = false
    and mn.deleted_at is null
);

commit;
