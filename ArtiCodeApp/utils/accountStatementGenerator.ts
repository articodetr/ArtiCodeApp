import { format } from 'date-fns';
import { ar } from 'date-fns/locale';
import { AccountMovement, CURRENCIES } from '@/types/database';
import { generatePDFHeaderHTML, generatePDFHeaderStyles } from './pdfHeaderGenerator';
import { isPostedMovement } from './movementApproval';

interface MovementWithBalance extends AccountMovement {
  runningBalance: number;
}

function getCurrencySymbol(code: string): string {
  const currency = CURRENCIES.find((c) => c.code === code);
  return currency?.symbol || code;
}

function getCurrencyName(code: string): string {
  const currency = CURRENCIES.find((c) => c.code === code);
  return currency?.name || code;
}

export function generateAccountStatementHTML(
  customerName: string,
  movements: AccountMovement[],
  logoDataUrl?: string,
  isProfitLossAccount?: boolean
): string {
  const allMovements = movements.filter((movement) => isPostedMovement(movement));

  const filteredMovements = allMovements
    .filter((m) => {
      if (isProfitLossAccount) {
        return true;
      }
      return !(m as any).is_commission_movement;
    })
    .sort((a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime());

  // Helper function to get combined amount including related commission
  const getCombinedAmount = (movement: AccountMovement): number => {
    const baseAmount = Number(movement.amount);
    const relatedCommissions = allMovements.filter(
      (m) =>
        (m as any).is_commission_movement === true &&
        (m as any).related_commission_movement_id === movement.id &&
        m.customer_id === movement.customer_id &&
        m.movement_type === movement.movement_type &&
        m.currency === movement.currency
    );
    const commissionTotal = relatedCommissions.reduce(
      (sum, m) => sum + Number(m.amount),
      0,
    );
    return baseAmount + commissionTotal;
  };

  // Group movements by currency
  const groupedByCurrency = filteredMovements.reduce((acc, movement) => {
    if (!acc[movement.currency]) {
      acc[movement.currency] = [];
    }
    acc[movement.currency].push(movement);

    return acc;
  }, {} as Record<string, AccountMovement[]>);

  const reportDate = format(new Date(), 'EEEE، dd MMMM yyyy', { locale: ar });

  // Helper function to split movements into pages
  const splitIntoPages = (movements: MovementWithBalance[], firstPageRows: number, subsequentPageRows: number) => {
    if (movements.length === 0) return [];

    const pages: MovementWithBalance[][] = [];
    let currentIndex = 0;

    // First page
    pages.push(movements.slice(0, Math.min(firstPageRows, movements.length)));
    currentIndex = firstPageRows;

    // Subsequent pages
    while (currentIndex < movements.length) {
      pages.push(movements.slice(currentIndex, currentIndex + subsequentPageRows));
      currentIndex += subsequentPageRows;
    }

    return pages;
  };

  // Generate sections for each currency
  const currencySections = Object.entries(groupedByCurrency).map(([curr, currMovements]) => {
    const movementsWithBalance: MovementWithBalance[] = [];
    let runningBalance = 0;

    currMovements.forEach((movement) => {
      const combinedAmount = getCombinedAmount(movement);

      if (movement.movement_type === 'incoming') {
        runningBalance += combinedAmount;
      } else {
        runningBalance -= combinedAmount;
      }

      movementsWithBalance.push({
        ...movement,
        runningBalance,
      });
    });

    const totalOutgoing = currMovements
      .filter(m => m.movement_type === 'outgoing')
      .reduce((sum, m) => sum + getCombinedAmount(m), 0);

    const totalIncoming = currMovements
      .filter(m => m.movement_type === 'incoming')
      .reduce((sum, m) => sum + getCombinedAmount(m), 0);

    const finalBalance = totalIncoming - totalOutgoing;
    const currencyName = getCurrencyName(curr);

    // Split movements into pages: 9 rows for first page, 13 rows for subsequent pages
    const pages = splitIntoPages(movementsWithBalance, 9, 13);

    // Generate HTML for each page
    const pageHTMLs = pages.map((pageMovements, pageIndex) => {
      const isFirstPage = pageIndex === 0;
      const isLastPage = pageIndex === pages.length - 1;

      const movementRows = pageMovements
        .map((movement) => {
          const balanceDisplay = movement.runningBalance > 0
            ? `${Math.round(movement.runningBalance).toLocaleString('en-US')} ${currencyName} (له)`
            : movement.runningBalance < 0
            ? `${Math.round(Math.abs(movement.runningBalance)).toLocaleString('en-US')} ${currencyName} (عليه)`
            : '-';

          const dateStr = format(new Date(movement.created_at), 'dd/MM/yyyy');
          const combinedAmount = getCombinedAmount(movement);
          const incomingAmount = movement.movement_type === 'incoming'
            ? Math.round(combinedAmount).toLocaleString('en-US')
            : '-';
          const outgoingAmount = movement.movement_type === 'outgoing'
            ? Math.round(combinedAmount).toLocaleString('en-US')
            : '-';

          return `
          <tr>
            <td class="cell text-center">${dateStr}</td>
            <td class="cell" style="text-align: right; padding-right: 12px;">${movement.notes || movement.movement_number}</td>
            <td class="cell text-center">${incomingAmount}</td>
            <td class="cell text-center">${outgoingAmount}</td>
            <td class="cell text-center">${balanceDisplay}</td>
          </tr>
          `;
        })
        .join('');

      const finalBalanceDisplay = finalBalance > 0
        ? `${Math.round(finalBalance).toLocaleString('en-US')} ${currencyName} (له)`
        : finalBalance < 0
        ? `${Math.round(Math.abs(finalBalance)).toLocaleString('en-US')} ${currencyName} (عليه)`
        : '-';

      const totalIncomingStr = totalIncoming > 0 ? Math.round(totalIncoming).toLocaleString('en-US') : '-';
      const totalOutgoingStr = totalOutgoing > 0 ? Math.round(totalOutgoing).toLocaleString('en-US') : '-';

      // Add summary rows only on the last page
      const summaryRows = isLastPage ? `
          <tr class="total-row">
            <td colspan="2" class="cell text-center">المجموع</td>
            <td class="cell text-center">${totalIncomingStr}</td>
            <td class="cell text-center">${totalOutgoingStr}</td>
            <td class="cell text-center">-</td>
          </tr>
          <tr class="final-row">
            <td colspan="4" class="cell text-center"><strong>الرصيد النهائي</strong></td>
            <td class="cell text-center"><strong>${finalBalanceDisplay}</strong></td>
          </tr>
      ` : '';

      return `
      <div class="page-wrapper ${isFirstPage ? 'first-page' : 'subsequent-page'}">
        ${isFirstPage ? `
        <div class="section-title">
          <h2>كشف حساب ${customerName} - ${currencyName}</h2>
        </div>
        ` : ''}
        <table>
          <thead>
            <tr>
              <th style="width: 12%;">التاريخ</th>
              <th style="width: 38%;">البيان</th>
              <th style="width: 15%;">له</th>
              <th style="width: 15%;">عليه</th>
              <th style="width: 20%;">الرصيد</th>
            </tr>
          </thead>
          <tbody>
            ${movementRows}
            ${summaryRows}
          </tbody>
        </table>
      </div>
      `;
    }).join('');

    return `
    <div class="currency-section">
      ${pageHTMLs}
    </div>
    `;
  }).join('');

  const headerHTML = generatePDFHeaderHTML({
    title: `كشف حساب العميل: ${customerName}`,
    logoDataUrl,
    primaryColor: '#382de3',
    darkColor: '#2821b8',
    height: 150,
    showPhones: true,
  });

  return `
<!DOCTYPE html>
<html dir="rtl" lang="ar">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>كشف الحساب - ${customerName}</title>
  <style>
    @page {
      margin: 1.5cm 1cm;
    }

    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }

    body {
      font-family: 'Arial', 'Tahoma', sans-serif;
      background: #fff;
      color: #000;
      direction: rtl;
      padding: 15px;
      -webkit-print-color-adjust: exact;
      print-color-adjust: exact;
    }

    .header-wrapper {
      margin-bottom: 25px;
      page-break-inside: avoid;
      page-break-after: avoid;
    }

    .currency-section {
      margin-bottom: 0;
    }

    .page-wrapper {
      page-break-inside: avoid;
      padding-top: 20px;
      padding-bottom: 30px;
    }

    .page-wrapper.first-page {
      padding-top: 0;
    }

    .page-wrapper.subsequent-page {
      page-break-before: always;
      padding-top: 40px;
    }

    .section-title {
      border: 2px solid #000;
      padding: 12px 20px;
      margin-bottom: 0;
      text-align: center;
      background: #f9fafb;
    }

    .section-title h2 {
      font-size: 20px;
      font-weight: bold;
      margin: 0;
      color: #111827;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      border: 2px solid #000;
      background: #fff;
    }

    .page-wrapper.first-page table {
      border-top: none;
    }

    th {
      background-color: #e5e7eb;
      font-weight: bold;
      padding: 10px 8px;
      border: 1px solid #000;
      font-size: 14px;
      text-align: center;
      color: #111827;
    }

    td {
      padding: 8px 6px;
      border: 1px solid #000;
      text-align: center;
      font-size: 13px;
      color: #374151;
      vertical-align: middle;
    }

    .text-center {
      text-align: center !important;
    }

    .cell {
      min-height: 30px;
    }

    .total-row {
      background-color: #f3f4f6;
      font-weight: bold;
      font-size: 14px;
    }

    .final-row {
      background-color: #dbeafe;
      font-weight: bold;
      font-size: 15px;
      color: #1e40af;
    }

    .footer {
      margin-top: 30px;
      text-align: center;
      font-size: 11px;
      color: #6b7280;
      padding: 10px 0;
      border-top: 1px solid #e5e7eb;
    }

    ${generatePDFHeaderStyles()}

    @media print {
      * {
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
        color-adjust: exact !important;
      }

      html, body {
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
      }

      @page {
        margin: 1.5cm 1cm;
      }

      .header-wrapper {
        page-break-inside: avoid;
        page-break-after: avoid;
      }

      .page-wrapper {
        page-break-inside: avoid;
      }

      .page-wrapper.subsequent-page {
        page-break-before: always;
      }

      table {
        page-break-inside: avoid;
      }

      th {
        background-color: #e5e7eb !important;
        -webkit-print-color-adjust: exact !important;
      }

      .total-row {
        background-color: #f3f4f6 !important;
        -webkit-print-color-adjust: exact !important;
      }

      .final-row {
        background-color: #dbeafe !important;
        -webkit-print-color-adjust: exact !important;
      }

      .section-title {
        background: #f9fafb !important;
        -webkit-print-color-adjust: exact !important;
      }
    }
  </style>
</head>
<body>
  <div class="header-wrapper">
    ${headerHTML}
  </div>

  ${currencySections}

  <div class="footer">
    <div>تاريخ الطباعة: ${reportDate}</div>
  </div>
</body>
</html>
  `;
}

export function generateAccountStatementForAllCurrencies(
  customerName: string,
  movements: AccountMovement[],
  logoDataUrl?: string,
  isProfitLossAccount?: boolean
): string {
  return generateAccountStatementHTML(customerName, movements, logoDataUrl, isProfitLossAccount);
}
