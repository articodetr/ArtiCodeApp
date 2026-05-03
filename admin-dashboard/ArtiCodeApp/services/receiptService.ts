import { AccountMovement } from '@/types/database';
import { generateReceiptHTML, generateQRCodeData } from '@/utils/receiptGenerator';
import { getReceiptLogoBase64 } from '@/utils/logoHelper';
import * as Print from 'expo-print';
import * as Sharing from 'expo-sharing';
import * as FileSystem from 'expo-file-system/legacy';

interface GenerateReceiptParams {
  movement: AccountMovement;
  customerName: string;
  qrCodeDataUrl?: string;
  commission?: number;
  destination?: string;
  transferNumber?: string;
  beneficiary?: string;
}

export async function generateAndShareReceipt(params: GenerateReceiptParams): Promise<void> {
  try {
    const { movement, customerName, qrCodeDataUrl = '', ...extraData } = params;

    let logoDataUrl: string | undefined;
    try {
      logoDataUrl = await getReceiptLogoBase64();
    } catch (logoError) {
      console.warn('[receiptService] Could not load logo, continuing without it:', logoError);
    }

    const html = generateReceiptHTML(
      {
        ...movement,
        customerName,
        ...extraData,
      },
      qrCodeDataUrl || getPlaceholderQRCode(),
      logoDataUrl
    );

    const { uri } = await Print.printToFileAsync({
      html,
      base64: false,
    });

    const pdfName = `receipt_${movement.receipt_number || movement.movement_number}.pdf`;
    const pdfPath = `${FileSystem.documentDirectory}${pdfName}`;

    await FileSystem.moveAsync({
      from: uri,
      to: pdfPath,
    });

    const canShare = await Sharing.isAvailableAsync();
    if (canShare) {
      await Sharing.shareAsync(pdfPath, {
        mimeType: 'application/pdf',
        dialogTitle: 'مشاركة السند',
        UTI: 'com.adobe.pdf',
      });
    } else {
      throw new Error('المشاركة غير متاحة على هذا الجهاز');
    }
  } catch (error) {
    console.error('[receiptService] Error in generateAndShareReceipt:', error);
    throw new Error('حدث خطأ أثناء إنشاء أو مشاركة السند. الرجاء المحاولة مرة أخرى.');
  }
}

export async function printReceipt(params: GenerateReceiptParams): Promise<void> {
  try {
    const { movement, customerName, qrCodeDataUrl = '', ...extraData } = params;

    let logoDataUrl: string | undefined;
    try {
      logoDataUrl = await getReceiptLogoBase64();
    } catch (logoError) {
      console.warn('[receiptService] Could not load logo, continuing without it:', logoError);
    }

    const html = generateReceiptHTML(
      {
        ...movement,
        customerName,
        ...extraData,
      },
      qrCodeDataUrl || getPlaceholderQRCode(),
      logoDataUrl
    );

    await Print.printAsync({
      html,
    });
  } catch (error) {
    console.error('[receiptService] Error in printReceipt:', error);
    throw new Error('حدث خطأ أثناء طباعة السند. الرجاء المحاولة مرة أخرى.');
  }
}

function getPlaceholderQRCode(): string {
  return 'data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMTIwIiBoZWlnaHQ9IjEyMCIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KICA8cmVjdCB3aWR0aD0iMTIwIiBoZWlnaHQ9IjEyMCIgZmlsbD0id2hpdGUiLz4KICA8ZyBmaWxsPSJibGFjayI+CiAgICA8cmVjdCB4PSIxMCIgeT0iMTAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iMjAiIHk9IjEwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjMwIiB5PSIxMCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSI0MCIgeT0iMTAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iNTAiIHk9IjEwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjYwIiB5PSIxMCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSI3MCIgeT0iMTAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iMTAiIHk9IjIwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjcwIiB5PSIyMCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSIxMCIgeT0iMzAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iMzAiIHk9IjMwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjQwIiB5PSIzMCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSI1MCIgeT0iMzAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iNzAiIHk9IjMwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjEwIiB5PSI0MCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSIzMCIgeT0iNDAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iNDAiIHk9IjQwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjUwIiB5PSI0MCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSI3MCIgeT0iNDAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iMTAiIHk9IjUwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjMwIiB5PSI1MCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSI0MCIgeT0iNTAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iNTAiIHk9IjUwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjcwIiB5PSI1MCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSIxMCIgeT0iNjAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iNzAiIHk9IjYwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjEwIiB5PSI3MCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSIyMCIgeT0iNzAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iMzAiIHk9IjcwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjQwIiB5PSI3MCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSI1MCIgeT0iNzAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iNjAiIHk9IjcwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjcwIiB5PSI3MCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSIzMCIgeT0iOTAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iNDAiIHk9IjkwIiB3aWR0aD0iMTAiIGhlaWdodD0iMTAiLz4KICAgIDxyZWN0IHg9IjUwIiB5PSI5MCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSI5MCIgeT0iMTAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iMTAwIiB5PSIxMCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSI5MCIgeT0iMjAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iMTAwIiB5PSIyMCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSI5MCIgeT0iNDAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iMTAwIiB5PSI0MCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgICA8cmVjdCB4PSI5MCIgeT0iNTAiIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCIvPgogICAgPHJlY3QgeD0iMTAwIiB5PSI1MCIgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIi8+CiAgPC9nPgo8L3N2Zz4=';
}
