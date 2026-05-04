import React from 'react';
import { Image, StyleSheet, Text, View } from 'react-native';
import { ImageIcon } from 'lucide-react-native';
import { LetterheadSettings } from '@/services/letterheadService';

const LETTERHEAD_WIDTH = 534;
const LETTERHEAD_HEIGHT = 176;
const ASPECT_RATIO = LETTERHEAD_WIDTH / LETTERHEAD_HEIGHT;

interface LetterheadPreviewProps {
  settings: LetterheadSettings;
  previewWidth?: number;
  showSizeLabel?: boolean;
}

export function LetterheadPreview({
  settings,
  previewWidth = LETTERHEAD_WIDTH,
  showSizeLabel = false,
}: LetterheadPreviewProps) {
  const width = Math.min(previewWidth, LETTERHEAD_WIDTH);
  const height = width / ASPECT_RATIO;
  const scale = width / LETTERHEAD_WIDTH;

  const outerPadding = 18 * scale;
  const logoSize = 108 * scale;
  const logoCircle = 132 * scale;
  const titleSize = Math.max(13, 19.5 * scale);
  const infoSize = Math.max(10, 12.8 * scale);

  return (
    <View style={styles.wrapper}>
      <View style={[styles.preview, { width, height, paddingHorizontal: outerPadding, paddingVertical: 26 * scale }]}>
        <View style={styles.topRow}>
          <View style={[styles.sideBlock, styles.leftBlock]}>
            <Text numberOfLines={1} style={[styles.englishName, { fontSize: titleSize }]}>
              {settings.english_name?.trim() || 'Company Name'}
            </Text>
            {settings.show_phone && !!settings.phone_number?.trim() && (
              <Text numberOfLines={1} style={[styles.englishMeta, { fontSize: infoSize }]}>
                {settings.phone_number}
              </Text>
            )}
            {!!settings.address_en?.trim() && (
              <Text numberOfLines={1} style={[styles.englishMeta, { fontSize: infoSize }]}>
                {settings.address_en}
              </Text>
            )}
          </View>

          <View style={styles.logoBlock}>
            {settings.show_logo && settings.logo_url ? (
              <View style={[styles.logoCircle, { width: logoCircle, height: logoCircle, borderRadius: logoCircle / 2 }]}>
                <Image
                  source={{ uri: settings.logo_url }}
                  style={{ width: logoSize, height: logoSize, borderRadius: 12 * scale }}
                  resizeMode="contain"
                />
              </View>
            ) : settings.show_logo ? (
              <View style={[styles.logoCircle, { width: logoCircle, height: logoCircle, borderRadius: logoCircle / 2 }]}>
                <ImageIcon size={42 * scale} color="#111111" />
              </View>
            ) : (
              <View style={[styles.logoSpacer, { width: logoCircle, height: logoCircle }]} />
            )}
          </View>

          <View style={[styles.sideBlock, styles.rightBlock]}>
            <Text numberOfLines={1} style={[styles.arabicName, { fontSize: titleSize }]}>
              {settings.business_name?.trim() || 'اسم الشركة'}
            </Text>
            {settings.show_phone && !!settings.phone_number?.trim() && (
              <Text numberOfLines={1} style={[styles.arabicMeta, { fontSize: infoSize }]}>
                {settings.phone_number}
              </Text>
            )}
            {!!settings.address_ar?.trim() && (
              <Text numberOfLines={1} style={[styles.arabicMeta, { fontSize: infoSize }]}>
                {settings.address_ar}
              </Text>
            )}
          </View>
        </View>

        <View style={styles.dividerWrap}>
          <View style={styles.dividerLine} />
        </View>
      </View>

      {showSizeLabel && (
        <Text style={styles.sizeLabel}>المعاينة الحالية للترويسة بشكل أحادي اللون</Text>
      )}
    </View>
  );
}

export { LETTERHEAD_WIDTH, LETTERHEAD_HEIGHT };

const styles = StyleSheet.create({
  wrapper: {
    alignItems: 'center',
  },
  preview: {
    backgroundColor: '#FFFFFF',
    borderWidth: 1,
    borderColor: '#D4D4D4',
    borderRadius: 12,
    overflow: 'hidden',
  },
  topRow: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
  },
  sideBlock: {
    flex: 1,
    minHeight: 72,
    justifyContent: 'flex-start',
  },
  leftBlock: {
    alignItems: 'flex-start',
    paddingTop: 4,
    paddingRight: 10,
  },
  rightBlock: {
    alignItems: 'flex-end',
    paddingTop: 4,
    paddingLeft: 10,
  },
  logoBlock: {
    width: 120,
    alignItems: 'center',
    justifyContent: 'center',
  },
  logoCircle: {
    borderWidth: 1.6,
    borderColor: '#111111',
    backgroundColor: '#FFFFFF',
    alignItems: 'center',
    justifyContent: 'center',
  },
  logoSpacer: {
    opacity: 0,
  },
  englishName: {
    fontWeight: '800',
    color: '#111111',
    textAlign: 'left',
  },
  englishMeta: {
    marginTop: 6,
    fontWeight: '500',
    color: '#4B5563',
    textAlign: 'left',
  },
  arabicName: {
    fontWeight: '800',
    color: '#111111',
    textAlign: 'right',
    writingDirection: 'rtl',
  },
  arabicMeta: {
    marginTop: 6,
    fontWeight: '500',
    color: '#4B5563',
    textAlign: 'right',
    writingDirection: 'rtl',
  },
  dividerWrap: {
    paddingTop: 12,
    alignItems: 'center',
  },
  dividerLine: {
    width: '100%',
    height: 1.4,
    backgroundColor: '#BDBDBD',
  },
  sizeLabel: {
    marginTop: 8,
    fontSize: 12,
    color: '#6B7280',
    textAlign: 'center',
  },
});