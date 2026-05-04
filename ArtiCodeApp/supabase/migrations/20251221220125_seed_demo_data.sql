/*
  # إضافة بيانات تجريبية

  1. البيانات التجريبية
    - 10 عملاء بأسماء عربية واقعية
    - 15 حوالة مالية بعملات مختلفة
    - 5 ديون بحالات مختلفة
    - أسعار صرف أولية للعملات الرئيسية

  2. الملاحظات
    - جميع البيانات تجريبية ويمكن حذفها بسهولة
    - أرقام الهواتف تجريبية
    - المبالغ متنوعة لعرض حالات مختلفة
*/

-- إضافة عملاء تجريبيين
INSERT INTO customers (id, name, phone, email, address, balance, notes, created_at, updated_at) VALUES
  ('11111111-1111-1111-1111-111111111111'::uuid, 'أحمد محمد العلي', '0501234567', 'ahmed.ali@example.com', 'الرياض، حي الملز', 1500.00, 'عميل مميز - تعاملات منتظمة', NOW() - INTERVAL '30 days', NOW()),
  ('22222222-2222-2222-2222-222222222222'::uuid, 'فاطمة علي السعيد', '0551234568', 'fatima.saeed@example.com', 'جدة، حي الروضة', -250.00, 'عميلة جديدة', NOW() - INTERVAL '25 days', NOW()),
  ('33333333-3333-3333-3333-333333333333'::uuid, 'محمود خالد الشمري', '0591234569', 'mahmoud.shamri@example.com', 'الدمام، حي الفيصلية', 3200.50, 'صاحب شركة استيراد وتصدير', NOW() - INTERVAL '20 days', NOW()),
  ('44444444-4444-4444-4444-444444444444'::uuid, 'سارة حسن القحطاني', '0561234570', 'sara.qahtani@example.com', 'الرياض، حي النخيل', 0.00, 'موظفة حكومية', NOW() - INTERVAL '15 days', NOW()),
  ('55555555-5555-5555-5555-555555555555'::uuid, 'عمر عبدالله المطيري', '0521234571', null, 'مكة المكرمة، العزيزية', 800.00, 'طالب جامعي', NOW() - INTERVAL '10 days', NOW()),
  ('66666666-6666-6666-6666-666666666666'::uuid, 'ليلى أحمد البكري', '0531234572', 'laila.bakri@example.com', 'المدينة المنورة', 0.00, 'مصممة جرافيك', NOW() - INTERVAL '8 days', NOW()),
  ('77777777-7777-7777-7777-777777777777'::uuid, 'يوسف حسين العتيبي', '0541234573', 'yousef.otaibi@example.com', 'الخبر', 2100.00, 'مهندس مدني', NOW() - INTERVAL '5 days', NOW()),
  ('88888888-8888-8888-8888-888888888888'::uuid, 'نورة سعيد الغامدي', '0571234574', 'noura.ghamdi@example.com', 'أبها', -500.00, 'طبيبة', NOW() - INTERVAL '3 days', NOW()),
  ('99999999-9999-9999-9999-999999999999'::uuid, 'خالد عمر الدوسري', '0581234575', null, 'الطائف', 450.00, 'سائق توصيل', NOW() - INTERVAL '2 days', NOW()),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid, 'منى محمد الزهراني', '0501234576', 'mona.zahrani@example.com', 'الرياض، حي السليمانية', 1000.00, 'معلمة رياضيات', NOW() - INTERVAL '1 day', NOW())
ON CONFLICT (id) DO NOTHING;

-- إضافة حوالات تجريبية
INSERT INTO transactions (id, transaction_number, customer_id, amount_sent, currency_sent, amount_received, currency_received, exchange_rate, status, notes, created_at) VALUES
  ('a1111111-1111-1111-1111-111111111111'::uuid, 'TXN-20241221-0001', '11111111-1111-1111-1111-111111111111'::uuid, 1000.00, 'USD', 34500.00, 'TRY', 34.50, 'completed', 'حوالة عاجلة', NOW() - INTERVAL '1 hour'),
  ('a2222222-2222-2222-2222-222222222222'::uuid, 'TXN-20241221-0002', '22222222-2222-2222-2222-222222222222'::uuid, 500.00, 'USD', 17250.00, 'TRY', 34.50, 'completed', null, NOW() - INTERVAL '3 hours'),
  ('a3333333-3333-3333-3333-333333333333'::uuid, 'TXN-20241220-0003', '33333333-3333-3333-3333-333333333333'::uuid, 2000.00, 'USD', 69000.00, 'TRY', 34.50, 'completed', 'دفعة للموردين', NOW() - INTERVAL '1 day'),
  ('a4444444-4444-4444-4444-444444444444'::uuid, 'TXN-20241220-0004', '44444444-4444-4444-4444-444444444444'::uuid, 800.00, 'USD', 3000.00, 'SAR', 3.75, 'completed', 'راتب شهري', NOW() - INTERVAL '1 day'),
  ('a5555555-5555-5555-5555-555555555555'::uuid, 'TXN-20241219-0005', '55555555-5555-5555-5555-555555555555'::uuid, 300.00, 'USD', 1125.00, 'SAR', 3.75, 'completed', 'مصروف دراسي', NOW() - INTERVAL '2 days'),
  ('a6666666-6666-6666-6666-666666666666'::uuid, 'TXN-20241219-0006', '11111111-1111-1111-1111-111111111111'::uuid, 1500.00, 'USD', 5625.00, 'SAR', 3.75, 'completed', null, NOW() - INTERVAL '2 days'),
  ('a7777777-7777-7777-7777-777777777777'::uuid, 'TXN-20241218-0007', '77777777-7777-7777-7777-777777777777'::uuid, 1200.00, 'USD', 1104.00, 'EUR', 0.92, 'completed', 'تحويل لألمانيا', NOW() - INTERVAL '3 days'),
  ('a8888888-8888-8888-8888-888888888888'::uuid, 'TXN-20241218-0008', '88888888-8888-8888-8888-888888888888'::uuid, 600.00, 'USD', 552.00, 'EUR', 0.92, 'completed', null, NOW() - INTERVAL '3 hours'),
  ('a9999999-9999-9999-9999-999999999999'::uuid, 'TXN-20241217-0009', '99999999-9999-9999-9999-999999999999'::uuid, 400.00, 'USD', 1468.00, 'AED', 3.67, 'completed', 'حوالة لدبي', NOW() - INTERVAL '4 days'),
  ('aaaaaaaa-aaaa-bbbb-cccc-aaaaaaaaaaaa'::uuid, 'TXN-20241217-0010', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid, 900.00, 'USD', 3303.00, 'AED', 3.67, 'completed', null, NOW() - INTERVAL '4 days'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'::uuid, 'TXN-20241216-0011', '33333333-3333-3333-3333-333333333333'::uuid, 5000.00, 'SAR', 46000.00, 'TRY', 9.20, 'completed', 'استثمار عقاري', NOW() - INTERVAL '5 days'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid, 'TXN-20241216-0012', '66666666-6666-6666-6666-666666666666'::uuid, 2000.00, 'SAR', 18400.00, 'TRY', 9.20, 'completed', null, NOW() - INTERVAL '5 days'),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid, 'TXN-20241215-0013', '77777777-7777-7777-7777-777777777777'::uuid, 850.00, 'EUR', 923.91, 'USD', 1.087, 'completed', 'تحويل من أوروبا', NOW() - INTERVAL '6 days'),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'::uuid, 'TXN-20241214-0014', '22222222-2222-2222-2222-222222222222'::uuid, 700.00, 'GBP', 886.08, 'USD', 1.2658, 'completed', 'تحويل من لندن', NOW() - INTERVAL '7 days'),
  ('ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid, 'TXN-20241213-0015', '33333333-3333-3333-3333-333333333333'::uuid, 5000.00, 'USD', 172500.00, 'TRY', 34.50, 'completed', 'صفقة تجارية كبيرة', NOW() - INTERVAL '8 days')
ON CONFLICT (transaction_number) DO NOTHING;

-- إضافة ديون تجريبية
INSERT INTO debts (id, customer_id, amount, currency, reason, status, paid_amount, due_date, created_at, paid_at) VALUES
  ('d1111111-1111-1111-1111-111111111111'::uuid, '22222222-2222-2222-2222-222222222222'::uuid, 250.00, 'USD', 'عجز في حوالة سابقة', 'pending', 0.00, NOW() + INTERVAL '10 days', NOW() - INTERVAL '5 days', null),
  ('d2222222-2222-2222-2222-222222222222'::uuid, '88888888-8888-8888-8888-888888888888'::uuid, 500.00, 'USD', 'قرض شخصي', 'partial', 200.00, NOW() + INTERVAL '15 days', NOW() - INTERVAL '12 days', null),
  ('d3333333-3333-3333-3333-333333333333'::uuid, '99999999-9999-9999-9999-999999999999'::uuid, 150.00, 'USD', 'رسوم حوالات سابقة', 'pending', 0.00, NOW() + INTERVAL '7 days', NOW() - INTERVAL '3 days', null),
  ('d4444444-4444-4444-4444-444444444444'::uuid, '11111111-1111-1111-1111-111111111111'::uuid, 300.00, 'USD', 'دين قديم', 'paid', 300.00, NOW() - INTERVAL '5 days', NOW() - INTERVAL '20 days', NOW() - INTERVAL '2 days'),
  ('d5555555-5555-5555-5555-555555555555'::uuid, '66666666-6666-6666-6666-666666666666'::uuid, 100.00, 'SAR', 'رسوم خدمة', 'pending', 0.00, NOW() + INTERVAL '5 days', NOW() - INTERVAL '1 day', null)
ON CONFLICT (id) DO NOTHING;

-- إضافة أسعار صرف أولية
INSERT INTO exchange_rates (id, from_currency, to_currency, rate, source, created_at) VALUES
  ('e1111111-1111-1111-1111-111111111111'::uuid, 'USD', 'TRY', 34.50, 'manual', NOW()),
  ('e2222222-2222-2222-2222-222222222222'::uuid, 'USD', 'SAR', 3.75, 'manual', NOW()),
  ('e3333333-3333-3333-3333-333333333333'::uuid, 'USD', 'EUR', 0.92, 'manual', NOW()),
  ('e4444444-4444-4444-4444-444444444444'::uuid, 'USD', 'GBP', 0.79, 'manual', NOW()),
  ('e5555555-5555-5555-5555-555555555555'::uuid, 'USD', 'AED', 3.67, 'manual', NOW()),
  ('e6666666-6666-6666-6666-666666666666'::uuid, 'SAR', 'TRY', 9.20, 'manual', NOW()),
  ('e7777777-7777-7777-7777-777777777777'::uuid, 'EUR', 'USD', 1.087, 'manual', NOW()),
  ('e8888888-8888-8888-8888-888888888888'::uuid, 'GBP', 'USD', 1.2658, 'manual', NOW()),
  ('e9999999-9999-9999-9999-999999999999'::uuid, 'TRY', 'USD', 0.029, 'manual', NOW()),
  ('eaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid, 'AED', 'USD', 0.272, 'manual', NOW())
ON CONFLICT (from_currency, to_currency) DO NOTHING;

-- إضافة إعدادات التطبيق الافتراضية (إذا لم تكن موجودة)
INSERT INTO app_settings (id, shop_name, shop_logo, shop_phone, shop_address, pin_code, updated_at) VALUES
  ('00000000-0000-0000-0000-000000000000'::uuid, 'محل الصيرفة السريع', null, '0500000000', 'الرياض، المملكة العربية السعودية', '1234', NOW())
ON CONFLICT (id) DO NOTHING;