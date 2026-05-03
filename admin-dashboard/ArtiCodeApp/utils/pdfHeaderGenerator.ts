import { COMPANY_INFO } from '@/constants/companyInfo';

export interface PDFHeaderOptions {
  title: string;
  logoDataUrl?: string;
  primaryColor?: string;
  darkColor?: string;
  height?: number;
  showPhones?: boolean;
}

export function generatePDFHeaderHTML(options: PDFHeaderOptions): string {
  const {
    title,
    logoDataUrl,
    primaryColor = '#382de3',
    darkColor = '#2821b8',
    height = 150,
    showPhones = true,
  } = options;

  // استخدام صورة البانر الكاملة
  const headerImageHTML = logoDataUrl && logoDataUrl !== '' && !logoDataUrl.includes('undefined')
    ? `<img src="${logoDataUrl}" alt="Header Banner" class="header-banner-image" onerror="this.style.display='none'" />`
    : `<img src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==" alt="Default Banner" class="header-banner-image" />`;

  return `
    <div class="pdf-header-banner">
      ${headerImageHTML}
    </div>

    <div class="document-title">${title}</div>
  `;
}

export function generatePDFHeaderStyles(): string {
  return `
    .pdf-header-banner {
      position: relative;
      width: 100%;
      height: auto;
      margin-bottom: 20px;
      overflow: hidden;
      flex-shrink: 0;
      box-sizing: border-box;
      -webkit-print-color-adjust: exact;
      print-color-adjust: exact;
    }

    .header-banner-image {
      width: 100%;
      height: auto;
      display: block;
      object-fit: contain;
      -webkit-print-color-adjust: exact;
      print-color-adjust: exact;
    }

    .document-title {
      text-align: center;
      font-size: 22px;
      font-weight: bold;
      color: #111827;
      margin: 18px 0 25px;
      padding: 8px;
    }

    .header-wrapper {
      position: relative;
      display: block;
    }

    @media print {
      * {
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
        color-adjust: exact !important;
      }

      .pdf-header-banner {
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
        color-adjust: exact !important;
        page-break-inside: avoid;
        page-break-after: avoid;
        box-sizing: border-box;
      }

      .header-wrapper {
        page-break-inside: avoid;
        page-break-after: avoid;
      }

      .header-banner-image {
        -webkit-print-color-adjust: exact !important;
        print-color-adjust: exact !important;
      }
    }
  `;
}
