import { format } from 'date-fns';
import { ar } from 'date-fns/locale';
import { AccountMovement, Currency, CURRENCIES } from '@/types/database';
import { COMPANY_INFO } from '@/constants/companyInfo';
import { numberToArabicTextWithCurrency } from './numberToArabicText';
import { getMovementApprovalLabel, normalizeMovementApprovalStatus } from './movementApproval';

interface ReceiptData extends AccountMovement {
  customerName: string;
  customerPhone?: string;
  customerAccountNumber?: string;
  commission?: number;
  commission_currency?: string;
  commission_recipient_name?: string;
  destination?: string;
  transferNumber?: string;
  beneficiary?: string;
  currentUserId?: string;
  linkedCustomerId?: string;
}

function getCurrencySymbol(code: string): string {
  const currency = CURRENCIES.find((c) => c.code === code);
  return currency?.symbol || code;
}

function getCurrencyName(code: string): string {
  const currency = CURRENCIES.find((c) => c.code === code);
  return currency?.name || code;
}

export function generateQRCodeData(receiptData: ReceiptData): string {
  const qrData = {
    receipt_number: receiptData.receipt_number,
    customer: receiptData.customerName,
    amount: receiptData.amount,
    currency: receiptData.currency,
    date: receiptData.created_at,
    type: receiptData.movement_type,
  };
  return JSON.stringify(qrData);
}


function escapeHtmlAttribute(value: string): string {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function renderReceiptHeader(logoDataUrl?: string): string {
  const fallbackHeader = '<img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==" alt="Default Banner" class="header-banner-image" />';

  if (!logoDataUrl) {
    return fallbackHeader;
  }

  if (logoDataUrl.startsWith('data:image/svg+xml')) {
    const commaIndex = logoDataUrl.indexOf(',');

    if (commaIndex !== -1) {
      const encodedSvg = logoDataUrl.slice(commaIndex + 1);

      try {
        const decodedSvg = decodeURIComponent(encodedSvg).trim();

        if (decodedSvg.startsWith('<svg')) {
          return decodedSvg;
        }
      } catch (error) {
        console.warn('[receiptGenerator] Could not decode SVG header, falling back to <img> rendering.', error);
      }
    }
  }

  return `<img src="${escapeHtmlAttribute(logoDataUrl)}" alt="Header Banner" class="header-banner-image" />`;
}

export function generateReceiptHTML(receiptData: ReceiptData, qrCodeDataUrl: string, logoDataUrl?: string): string {
  const {
    receipt_number,
    customerName,
    customerAccountNumber,
    amount,
    currency,
    commission = 0,
    commission_currency = 'YER',
    movement_type,
    notes,
    created_at,
    destination,
    transferNumber,
    beneficiary,
    sender_name,
    beneficiary_name,
    transfer_number,
    currentUserId,
    created_by_user_id,
    linkedCustomerId,
  } = receiptData;

  const receiptDate = format(new Date(created_at), 'yyyy-MM-dd', { locale: ar });
  const receiptTime = format(new Date(created_at), 'HH:mm:ss', { locale: ar });
  const receiptDateTime = format(new Date(created_at), 'dd/MM/yyyy', { locale: ar });

  const isTransfer = Boolean(receiptData.transfer_direction);
  const approvalStatus = normalizeMovementApprovalStatus(receiptData);
  const approvalLabel = getMovementApprovalLabel(receiptData);
  const approvalMeta =
    approvalStatus === 'pending'
      ? {
          background: '#FEF3C7',
          border: '#F59E0B',
          color: '#B45309',
          note: 'هذه الحركة بانتظار الموافقة ولن تؤثر في الإجماليات قبل القبول.',
        }
      : approvalStatus === 'rejected'
        ? {
            background: '#FEE2E2',
            border: '#EF4444',
            color: '#B91C1C',
            note: 'هذه الحركة مرفوضة ولن تؤثر في الإجماليات.',
          }
        : {
            background: '#DCFCE7',
            border: '#22C55E',
            color: '#15803D',
            note: 'تم اعتماد هذه الحركة وأصبحت مؤثرة في الإجماليات.',
          };

  const isCreator = currentUserId && created_by_user_id && currentUserId === created_by_user_id;
  const isLinkedView = linkedCustomerId && !isCreator;

  const perspectiveType = isLinkedView
    ? (movement_type === 'outgoing' ? 'incoming' : 'outgoing')
    : movement_type;

  const receiptType = isTransfer
    ? 'تحويل'
    : perspectiveType === 'outgoing' ? 'دائن' : 'مدين';

  const currencyName = getCurrencyName(currency);
  const commissionCurrencyName = getCurrencyName(commission_currency);

  const netAmount = Number(amount) - Number(commission || 0);

  const amountInWords = numberToArabicTextWithCurrency(netAmount, currency as Currency);

  const actionTitle = isTransfer
    ? receiptData.transfer_direction === 'customer_to_customer'
      ? 'تحويل داخلي بين عميلين'
      : receiptData.transfer_direction === 'shop_to_customer'
      ? 'تحويل من المحل للعميل'
      : 'تحويل من العميل للمحل'
    : perspectiveType === 'outgoing' ? 'تسليم للعميل' : 'استلام من العميل';

  const primaryColor = '#12b8de';
  const darkColor = '#00a0c4';

  return `
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>إيصال تحويل أموال</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Cairo:wght@400;600;700;800&display=swap" rel="stylesheet">

  <style>
    @import url('https://fonts.googleapis.com/css2?family=Cairo:wght@400;600;700;800&display=block');

    * {
      box-sizing: border-box;
      font-family: 'Cairo', 'Tahoma', 'Arial', sans-serif;
      -webkit-font-smoothing: antialiased;
      -moz-osx-font-smoothing: grayscale;
    }

    body {
      width: 100%;
      min-height: 100vh;
      background: #f5f5f5;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 20px;
      font-family: 'Cairo', 'Tahoma', 'Arial', sans-serif;
      direction: rtl;
      margin: 0;
      -webkit-print-color-adjust: exact;
      print-color-adjust: exact;
    }

    .receipt-page {
      width: 100%;
      min-height: 100vh;
      background: #f5f5f5;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 20px;
      direction: rtl;
      gap: 20px;
    }

    .receipt-container {
      width: 900px;
      height: 634px;
      background: #ffffff;
      border: 3px solid ${primaryColor};
      border-radius: 24px;
      padding: 8px;
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
    }

    .receipt-inner-frame {
      width: 100%;
      height: 100%;
      border: 2px solid ${primaryColor};
      border-radius: 18px;
      background: #ffffff;
      overflow: hidden;
      display: flex;
      flex-direction: column;
    }

    .receipt-header {
      position: relative;
      width: 100%;
      height: auto;
      border-radius: 18px 18px 0 0;
      overflow: hidden;
      flex-shrink: 0;
    }

    .header-banner-image {
      width: 100%;
      height: auto;
      display: block;
      object-fit: contain;
    }

    .receipt-content {
      flex: 1;
      min-height: 0;
      padding: 8px 16px;
      display: flex;
      flex-direction: column;
      gap: 6px;
      overflow: hidden;
    }

    .title-row {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 10px;
    }

    .date-pill,
    .document-pill {
      background: #ffffff;
      border: 2px solid ${primaryColor};
      border-radius: 20px;
      padding: 0 16px;
      display: flex;
      align-items: center;
      gap: 6px;
      font-size: 13px;
      height: 38px;
      flex-shrink: 0;
    }

    .pill-label {
      color: #dc2626;
      font-weight: 700;
      line-height: 1;
      margin: 0;
      padding: 0;
    }

    .pill-value {
      color: #000000;
      font-weight: 700;
      line-height: 1;
      margin: 0;
      padding: 0;
    }

    .action-title {
      background: linear-gradient(135deg, ${primaryColor} 0%, ${darkColor} 100%);
      color: #ffffff;
      border-radius: 22px;
      padding: 0 50px;
      height: 52px;
      font-size: 20px;
      font-weight: 800;
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.2);
      display: flex;
      align-items: center;
      justify-content: center;
      line-height: 1;
      flex-shrink: 0;
    }

    .customer-row {
      display: flex;
      gap: 8px;
      align-items: center;
    }

    .account-number-box,
    .account-label-box,
    .customer-name-box,
    .customer-label-box {
      background: #ffffff;
      border: 2px solid ${primaryColor};
      border-radius: 16px;
      height: 38px;
      display: flex;
      align-items: center;
      justify-content: center;
    }

    .account-number-box {
      padding: 0 16px;
    }

    .account-label-box {
      padding: 0 14px;
    }

    .customer-name-box {
      flex: 1;
      padding: 0 16px;
      text-align: center;
      font-size: 14px;
      font-weight: 700;
      line-height: 1;
      color: #000000;
    }

    .customer-label-box {
      padding: 0 20px;
      color: #2563eb;
      font-size: 13px;
      font-weight: 700;
      line-height: 1;
    }

    .account-value {
      color: #000000;
      font-size: 14px;
      font-weight: 700;
      line-height: 1;
    }

    .account-label {
      color: #2563eb;
      font-size: 13px;
      font-weight: 700;
      line-height: 1;
      text-decoration: none;
    }

    .notice-row {
      width: 100%;
    }

    .approval-row {
      width: 100%;
    }

    .approval-pill {
      border: 2px solid ${approvalMeta.border};
      border-radius: 16px;
      padding: 8px 14px;
      text-align: center;
      font-size: 13px;
      font-weight: 800;
      color: ${approvalMeta.color};
      background: ${approvalMeta.background};
      line-height: 1.5;
    }

    .notice-box {
      border: 2px solid ${primaryColor};
      border-radius: 16px;
      padding: 6px 14px;
      text-align: center;
      font-size: 12px;
      font-weight: 600;
      color: #000000;
      background: #ffffff;
      line-height: 1.4;
    }

    .four-cards-row {
      display: flex;
      gap: 6px;
      justify-content: center;
    }

    .info-card {
      flex: 1;
      border: 2px solid ${primaryColor};
      border-radius: 16px;
      padding: 0;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 4px;
      background: #ffffff;
      height: 60px;
      flex-shrink: 0;
    }

    .card-label {
      color: #2563eb;
      font-size: 10px;
      font-weight: 700;
      text-align: center;
      line-height: 1;
      margin: 0;
      padding: 0;
      text-decoration: none;
    }

    .card-value {
      color: #000000;
      font-size: 16px;
      font-weight: 700;
      text-align: center;
      line-height: 1;
      margin: 0;
      padding: 0;
    }

    .card-currency {
      font-size: 11px;
      font-weight: 600;
    }

    .amount-words-row {
      width: 100%;
    }

    .amount-words-box {
      border: 2px solid ${primaryColor};
      border-radius: 16px;
      padding: 6px 14px;
      text-align: center;
      font-size: 14px;
      font-weight: 700;
      color: #000000;
      background: #ffffff;
      line-height: 1.2;
    }

    .statement-code-row {
      display: flex;
      gap: 6px;
    }

    .statement-box {
      flex: 1;
      border: 2px solid ${primaryColor};
      border-radius: 16px;
      padding: 0;
      font-size: 13px;
      background: #ffffff;
      text-align: center;
      display: flex;
      align-items: center;
      justify-content: center;
      height: 45px;
      flex-shrink: 0;
    }

    .code-box {
      width: 100px;
      border: 2px solid ${primaryColor};
      border-radius: 16px;
      padding: 0;
      font-size: 13px;
      background: #ffffff;
      text-align: center;
      display: flex;
      align-items: center;
      justify-content: center;
      height: 45px;
      flex-shrink: 0;
    }

    .box-label {
      color: #2563eb;
      font-weight: 700;
      line-height: 1;
      margin: 0;
      padding: 0;
      text-decoration: none;
    }

    .bottom-section {
      display: flex;
      gap: 8px;
      min-height: 0;
    }

    .qr-container {
      width: 100px;
      height: 100px;
      flex-shrink: 0;
    }

    .qr-placeholder {
      width: 100%;
      height: 100%;
      border: 2px solid ${primaryColor};
      border-radius: 16px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 16px;
      font-weight: 700;
      color: #9ca3af;
      background: #ffffff;
      line-height: 1;
    }

    .qr-placeholder img {
      width: 100%;
      height: 100%;
      object-fit: cover;
      display: block;
      border-radius: 14px;
    }

    .transfer-details {
      flex: 1;
      border: 2px solid ${primaryColor};
      border-radius: 16px;
      padding: 8px 14px;
      display: flex;
      flex-direction: column;
      gap: 4px;
      background: #ffffff;
      justify-content: center;
      min-height: 100px;
      overflow: hidden;
    }

    .detail-row {
      display: flex;
      align-items: center;
      gap: 8px;
      font-size: 12px;
      line-height: 1.5;
    }

    .detail-label {
      color: #000000;
      font-weight: 700;
      flex-shrink: 0;
      min-width: fit-content;
    }

    .detail-value {
      color: #000000;
      font-weight: 600;
      flex: 1;
    }

    .final-notice-row {
      display: flex;
      gap: 6px;
      align-items: center;
      flex-shrink: 0;
    }

    .notice-bar {
      flex: 1;
      background: linear-gradient(135deg, ${primaryColor} 0%, ${darkColor} 100%);
      color: #ffffff;
      border-radius: 16px;
      padding: 6px 16px;
      text-align: center;
      font-size: 12px;
      font-weight: 700;
      display: flex;
      align-items: center;
      justify-content: center;
      line-height: 1;
    }

    .timestamp-pill {
      background: linear-gradient(135deg, ${primaryColor} 0%, ${darkColor} 100%);
      color: #ffffff;
      border-radius: 16px;
      padding: 6px 14px;
      font-size: 10px;
      font-weight: 700;
      white-space: nowrap;
      direction: ltr;
      display: flex;
      align-items: center;
      justify-content: center;
      line-height: 1;
    }

    .receipt-container.exporting .receipt-content {
      padding: 6px 14px;
      gap: 4px;
    }

    .receipt-container.exporting .action-title,
    .receipt-container.exporting .date-pill,
    .receipt-container.exporting .document-pill,
    .receipt-container.exporting .account-number-box,
    .receipt-container.exporting .account-label-box,
    .receipt-container.exporting .customer-name-box,
    .receipt-container.exporting .customer-label-box,
    .receipt-container.exporting .info-card,
    .receipt-container.exporting .statement-box,
    .receipt-container.exporting .code-box,
    .receipt-container.exporting .notice-bar,
    .receipt-container.exporting .timestamp-pill,
    .receipt-container.exporting .notice-box,
    .receipt-container.exporting .amount-words-box {
      display: flex !important;
      align-items: center !important;
      justify-content: center !important;
    }

    .receipt-container.exporting .pill-label,
    .receipt-container.exporting .pill-value,
    .receipt-container.exporting .account-label,
    .receipt-container.exporting .account-value,
    .receipt-container.exporting .card-label,
    .receipt-container.exporting .card-value,
    .receipt-container.exporting .box-label,
    .receipt-container.exporting .notice-bar,
    .receipt-container.exporting .timestamp-pill,
    .receipt-container.exporting .action-title {
      line-height: 1 !important;
      padding-top: 0 !important;
      padding-bottom: 0 !important;
      transform: translateY(-1px) !important;
    }

    .receipt-container.exporting .contact-box-title,
    .receipt-container.exporting .contact-box-phone,
    .receipt-container.exporting .company-name-ar-line,
    .receipt-container.exporting .company-name-en,
    .receipt-container.exporting .pill-label,
    .receipt-container.exporting .pill-value {
      white-space: nowrap !important;
    }

    .receipt-container.exporting span,
    .receipt-container.exporting div {
      line-height: 1 !important;
      vertical-align: middle !important;
    }

    .receipt-container.exporting .action-title,
    .receipt-container.exporting .pill-label,
    .receipt-container.exporting .pill-value,
    .receipt-container.exporting .account-label,
    .receipt-container.exporting .account-value,
    .receipt-container.exporting .card-label,
    .receipt-container.exporting .card-value,
    .receipt-container.exporting .box-label,
    .receipt-container.exporting .notice-bar,
    .receipt-container.exporting .timestamp-pill,
    .receipt-container.exporting .notice-box,
    .receipt-container.exporting .amount-words-box,
    .receipt-container.exporting .detail-label,
    .receipt-container.exporting .detail-value {
      transform: translateY(-2px) !important;
      display: inline-block !important;
      line-height: 1.1 !important;
    }

    @media print {
      * {
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
        color-adjust: exact !important;
      }

      html {
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
      }

      body * {
        visibility: hidden;
      }

      .receipt-container,
      .receipt-container * {
        visibility: visible;
      }

      .receipt-page {
        padding: 0;
        margin: 0;
        background: #ffffff;
        min-height: auto !important;
        height: auto !important;
        display: block !important;
      }

      .receipt-container {
        position: relative !important;
        left: 0 !important;
        top: 0 !important;
        transform: none !important;
        margin: 0 auto !important;
        box-shadow: none;
        page-break-inside: avoid;
        page-break-after: avoid;
        max-width: 900px;
        max-height: 634px;
        width: 900px;
        height: 634px;
      }

      .receipt-header {
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
      }

      .action-title,
      .notice-bar,
      .timestamp-pill {
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
        background: linear-gradient(135deg, ${primaryColor} 0%, ${darkColor} 100%) !important;
      }

      .header-banner-image {
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
      }

      .date-pill,
      .document-pill,
      .account-number-box,
      .account-label-box,
      .customer-name-box,
      .customer-label-box,
      .notice-box,
      .info-card,
      .amount-words-box,
      .statement-box,
      .code-box,
      .qr-placeholder,
      .transfer-details {
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
      }

      .pill-label,
      .account-label,
      .card-label,
      .box-label,
      .customer-label-box {
        color: #2563eb !important;
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
      }

      .receipt-container,
      .receipt-inner-frame,
      .receipt-header,
      .receipt-content {
        page-break-inside: avoid !important;
        page-break-before: avoid !important;
        page-break-after: avoid !important;
        break-inside: avoid !important;
      }

      .receipt-container * {
        orphans: 3 !important;
        widows: 3 !important;
      }

      @page {
        size: A4 landscape;
        margin: 0;
      }

      html,
      body {
        margin: 0 !important;
        padding: 0 !important;
        height: auto !important;
        min-height: 100% !important;
        overflow: visible !important;
      }

      body {
        display: flex !important;
        align-items: flex-start !important;
        justify-content: center !important;
      }
    }
  </style>
</head>

<body>
  <div class="receipt-page">
    <div class="receipt-container">
      <div class="receipt-inner-frame">
        <div class="receipt-header">
          ${renderReceiptHeader(logoDataUrl)}
        </div>

        <div class="receipt-content">
          <div class="title-row">
            <div class="date-pill">
              <span class="pill-label">التاريخ:</span>
              <span class="pill-value">${receiptDate}</span>
            </div>

            <div class="action-title">${actionTitle}</div>

            <div class="document-pill">
              <span class="pill-label">رقم المستند:</span>
              <span class="pill-value">${receipt_number || '000000'}</span>
            </div>
          </div>

          <div class="customer-row">
            <div class="customer-label-box">عميلنا</div>
            <div class="customer-name-box">${customerName}</div>
            <div class="account-label-box">
              <span class="account-label">رقم الحساب:</span>
            </div>
            <div class="account-number-box">
              <span class="account-value">${customerAccountNumber || '000000'}</span>
            </div>
          </div>

          <div class="approval-row">
            <div class="approval-pill">
              <strong>الحالة:</strong> ${approvalLabel} - ${approvalMeta.note}
            </div>
          </div>

          <div class="notice-row">
            <div class="notice-box">
              نود إشعاركم ${isTransfer
                ? receiptData.transfer_direction === 'customer_to_customer'
                  ? `بتحويل المبلغ المذكور من ${sender_name || 'العميل الأول'} إلى ${beneficiary_name || 'العميل الثاني'}`
                  : receiptData.transfer_direction === 'shop_to_customer'
                  ? 'بتحويل المبلغ المذكور من المحل إليكم'
                  : 'باستلام المبلغ المذكور منكم وتحويله للمحل'
                : `أننا ${perspectiveType === 'outgoing' ? 'سلمنا لكم حسب توجيهكم لنا بتسليم المبلغ المذكور' : 'استلمنا منكم حسب توجيهكم لنا باستلام المبلغ المذكور'}`} حسب التفاصيل التالية
            </div>
          </div>

          <div class="four-cards-row">
            <div class="info-card">
              <div class="card-label">المبلغ الإجمالي</div>
              <div class="card-value">${amount} <span class="card-currency">${getCurrencySymbol(currency)}</span></div>
            </div>

            <div class="info-card">
              <div class="card-label">عملة الحساب</div>
              <div class="card-value">${currencyName}</div>
            </div>

            <div class="info-card">
              <div class="card-label">العمولة</div>
              <div class="card-value">
                ${commission || 0} <span class="card-currency">${commission > 0 ? commissionCurrencyName : ''}</span>
              </div>
            </div>

            <div class="info-card">
              <div class="card-label">الصافي</div>
              <div class="card-value">${netAmount} <span class="card-currency">${getCurrencySymbol(currency)}</span></div>
            </div>
          </div>

          <div class="amount-words-row">
            <div class="amount-words-box">${amountInWords}</div>
          </div>

          <div class="statement-code-row">
            <div class="statement-box">
              <span class="box-label">البيان</span>
            </div>
            <div class="code-box">
              <span class="box-label">${transfer_number || 'الكود'}</span>
            </div>
          </div>

          <div class="bottom-section">
            <div class="transfer-details">
              <div class="detail-row">
                <span class="detail-label">رقم الحوالة:</span>
                <span class="detail-value">${transfer_number || 'غير محدد'}</span>
              </div>
              <div class="detail-row">
                <span class="detail-label">${isLinkedView ? (perspectiveType === 'outgoing' ? 'المستلم' : 'المرسل') : (perspectiveType === 'outgoing' ? 'المرسل' : 'المستلم')}:</span>
                <span class="detail-value">${isLinkedView ? customerName : (sender_name || customerName)}</span>
              </div>
              <div class="detail-row">
                <span class="detail-label">${isLinkedView ? (perspectiveType === 'outgoing' ? 'المرسل' : 'المستلم') : (perspectiveType === 'outgoing' ? 'المستلم' : 'المرسل')}:</span>
                <span class="detail-value">${isLinkedView ? (beneficiary_name || customerName) : (beneficiary_name || 'غير محدد')}</span>
              </div>
              ${commission && commission > 0 ? `
              <div class="detail-row">
                <span class="detail-label">مستلم العمولة:</span>
                <span class="detail-value">${receiptData.commission_recipient_name || 'الأرباح والخسائر'}</span>
              </div>
              ` : ''}
              <div class="detail-row">
                <span class="detail-label">نوع الحركة:</span>
                <span class="detail-value">${perspectiveType === 'outgoing' ? 'له (دائن)' : 'عليه (مدين)'}</span>
              </div>
              <div class="detail-row">
                <span class="detail-label">ملاحظات:</span>
                <span class="detail-value">${notes || 'لا توجد ملاحظات'}</span>
              </div>
            </div>

            <div class="qr-container">
              ${
                qrCodeDataUrl
                  ? `<img src="${qrCodeDataUrl}" alt="QR Code" style="width: 100%; height: 100%; border-radius: 14px;" />`
                  : '<div class="qr-placeholder">QR</div>'
              }
            </div>
          </div>

          <div class="final-notice-row">
            <div class="timestamp-pill">${receiptDateTime} م ${receiptTime}</div>
            <div class="notice-bar">هذا الإشعار لا يلزم ختم أو توقيع</div>
          </div>
        </div>
      </div>
    </div>
  </div>
</body>
</html>
`;
}
