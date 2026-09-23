import 'package:hugeicons/hugeicons.dart';
import 'package:material_ui/material_ui.dart';

/// The one icon language used by Kapy Notes.
///
/// Hugeicons ships its free stroke-rounded set as vector path data rather
/// than as an icon font. Keeping those paths behind this small semantic layer
/// gives the app one consistent 1.5 px stroke and keeps call sites independent
/// from the package's generated names.
class KapyIconData {
  const KapyIconData(this.codePoint, this.paths);

  /// A stable identifier used by tests and diagnostics.
  final int codePoint;
  final List<List<dynamic>> paths;
}

/// The app-wide Hugeicons renderer.
class KapyIcon extends StatelessWidget {
  const KapyIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
    this.textDirection,
    this.strokeWidth = 1.5,
  });

  final KapyIconData icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;
  final TextDirection? textDirection;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    Widget glyph = HugeIcon(
      icon: icon.paths,
      size: size,
      color: color,
      strokeWidth: strokeWidth,
    );

    final label = semanticLabel;
    if (label != null) {
      glyph = Semantics(
        label: label,
        child: ExcludeSemantics(child: glyph),
      );
    }
    return glyph;
  }
}

/// Semantic app icons, all drawn from Hugeicons' stroke-rounded family.
class KapyIcons {
  const KapyIcons._();

  static const accountCircleOutlined = KapyIconData(
    0xE001,
    HugeIcons.strokeRoundedUserCircle,
  );
  static const addAPhotoOutlined = KapyIconData(
    0xE002,
    HugeIcons.strokeRoundedCameraAdd01,
  );
  static const addRounded = KapyIconData(0xE003, HugeIcons.strokeRoundedAdd01);
  static const arrowBackRounded = KapyIconData(
    0xE004,
    HugeIcons.strokeRoundedArrowLeft02,
  );
  static const articleOutlined = KapyIconData(
    0xE005,
    HugeIcons.strokeRoundedFile02,
  );
  static const magicOutlined = KapyIconData(
    0xE006,
    HugeIcons.strokeRoundedAiMagic,
  );
  static const storiesOutlined = KapyIconData(
    0xE007,
    HugeIcons.strokeRoundedBookOpen01,
  );
  static const blockedRounded = KapyIconData(
    0xE008,
    HugeIcons.strokeRoundedBlocked,
  );
  static const blurRounded = KapyIconData(0xE009, HugeIcons.strokeRoundedBlur);
  static const appearanceOutlined = KapyIconData(
    0xE00A,
    HugeIcons.strokeRoundedSun03,
  );
  static const brokenImageOutlined = KapyIconData(
    0xE00B,
    HugeIcons.strokeRoundedImageNotFound01,
  );
  static const calendarOutlined = KapyIconData(
    0xE00C,
    HugeIcons.strokeRoundedCalendar03,
  );
  static const cameraOutlined = KapyIconData(
    0xE00D,
    HugeIcons.strokeRoundedCamera01,
  );
  static const cameraSwitchRounded = KapyIconData(
    0xE00E,
    HugeIcons.strokeRoundedCameraRotated01,
  );
  static const cancelRounded = KapyIconData(
    0xE00F,
    HugeIcons.strokeRoundedCancelCircle,
  );
  static const checkCircleRounded = KapyIconData(
    0xE010,
    HugeIcons.strokeRoundedCheckmarkCircle02,
  );
  static const checkRounded = KapyIconData(
    0xE011,
    HugeIcons.strokeRoundedTick02,
  );
  static const checklistRounded = KapyIconData(
    0xE012,
    HugeIcons.strokeRoundedCheckList,
  );
  static const chevronLeftRounded = KapyIconData(
    0xE013,
    HugeIcons.strokeRoundedArrowLeft01,
  );
  static const chevronRightRounded = KapyIconData(
    0xE014,
    HugeIcons.strokeRoundedArrowRight01,
  );
  static const chevronDownRounded = KapyIconData(
    0xE06A,
    HugeIcons.strokeRoundedArrowDown01,
  );
  static const circleOutlined = KapyIconData(
    0xE015,
    HugeIcons.strokeRoundedCircle,
  );
  static const closeRounded = KapyIconData(
    0xE016,
    HugeIcons.strokeRoundedCancel01,
  );
  static const closeFullscreenRounded = KapyIconData(
    0xE017,
    HugeIcons.strokeRoundedMinimizeScreen,
  );
  static const cloudOffRounded = KapyIconData(
    0xE018,
    HugeIcons.strokeRoundedCloudOff,
  );
  static const copyRounded = KapyIconData(
    0xE019,
    HugeIcons.strokeRoundedCopy01,
  );
  static const copyAllOutlined = KapyIconData(
    0xE01A,
    HugeIcons.strokeRoundedCopy02,
  );
  static const currencyExchangeRounded = KapyIconData(
    0xE01B,
    HugeIcons.strokeRoundedMoneyExchange01,
  );
  static const deleteForeverOutlined = KapyIconData(
    0xE01C,
    HugeIcons.strokeRoundedDelete04,
  );
  static const deleteOutlined = KapyIconData(
    0xE01D,
    HugeIcons.strokeRoundedDelete02,
  );
  static const deleteSweepOutlined = KapyIconData(
    0xE01E,
    HugeIcons.strokeRoundedDeleteThrow,
  );
  static const descriptionOutlined = KapyIconData(
    0xE01F,
    HugeIcons.strokeRoundedFile02,
  );
  static const downloadRounded = KapyIconData(
    0xE020,
    HugeIcons.strokeRoundedDownload04,
  );
  static const dragRounded = KapyIconData(
    0xE021,
    HugeIcons.strokeRoundedDragDropVertical,
  );
  static const editNoteRounded = KapyIconData(
    0xE022,
    HugeIcons.strokeRoundedNoteEdit,
  );
  static const editOutlined = KapyIconData(
    0xE023,
    HugeIcons.strokeRoundedEdit02,
  );
  static const errorOutlined = KapyIconData(
    0xE024,
    HugeIcons.strokeRoundedAlertCircle,
  );
  static const flagOutlined = KapyIconData(
    0xE025,
    HugeIcons.strokeRoundedFlag02,
  );
  static const flashAutoRounded = KapyIconData(
    0xE026,
    HugeIcons.strokeRoundedFlash,
  );
  static const flashOffRounded = KapyIconData(
    0xE027,
    HugeIcons.strokeRoundedFlashOff,
  );
  static const formatBoldRounded = KapyIconData(
    0xE028,
    HugeIcons.strokeRoundedTextBold,
  );
  static const indentDecreaseRounded = KapyIconData(
    0xE029,
    HugeIcons.strokeRoundedListIndentDecrease,
  );
  static const indentIncreaseRounded = KapyIconData(
    0xE02A,
    HugeIcons.strokeRoundedListIndentIncrease,
  );
  static const formatItalicRounded = KapyIconData(
    0xE02B,
    HugeIcons.strokeRoundedTextItalic,
  );
  static const bulletedListRounded = KapyIconData(
    0xE02C,
    HugeIcons.strokeRoundedLeftToRightListBullet,
  );
  static const audioWaveRounded = KapyIconData(
    0xE02D,
    HugeIcons.strokeRoundedAudioWave01,
  );
  static const historyRounded = KapyIconData(
    0xE02E,
    HugeIcons.strokeRoundedTransactionHistory,
  );
  static const historyOffRounded = KapyIconData(
    0xE02F,
    HugeIcons.strokeRoundedClock05,
  );
  static const hourglassRounded = KapyIconData(
    0xE030,
    HugeIcons.strokeRoundedHourglass,
  );
  static const imageOutlined = KapyIconData(
    0xE031,
    HugeIcons.strokeRoundedImage01,
  );
  static const infoOutlined = KapyIconData(
    0xE032,
    HugeIcons.strokeRoundedInformationCircle,
  );
  static const shareRounded = KapyIconData(
    0xE033,
    HugeIcons.strokeRoundedShare08,
  );
  static const keyboardOutlined = KapyIconData(
    0xE034,
    HugeIcons.strokeRoundedKeyboard,
  );
  static const linkRounded = KapyIconData(
    0xE035,
    HugeIcons.strokeRoundedLink01,
  );
  static const unlockRounded = KapyIconData(
    0xE036,
    HugeIcons.strokeRoundedSquareUnlock02,
  );
  static const lockRounded = KapyIconData(
    0xE037,
    HugeIcons.strokeRoundedSquareLock02,
  );
  static const loginRounded = KapyIconData(
    0xE038,
    HugeIcons.strokeRoundedLogin03,
  );
  static const logoutRounded = KapyIconData(
    0xE039,
    HugeIcons.strokeRoundedLogout03,
  );
  static const mailOutlined = KapyIconData(
    0xE03A,
    HugeIcons.strokeRoundedMail01,
  );
  static const menuOpenRounded = KapyIconData(
    0xE03B,
    HugeIcons.strokeRoundedSidebarLeft,
  );
  static const menuRounded = KapyIconData(
    0xE03C,
    HugeIcons.strokeRoundedMenu01,
  );
  static const micRounded = KapyIconData(0xE03D, HugeIcons.strokeRoundedMic01);
  static const moreRounded = KapyIconData(
    0xE03E,
    HugeIcons.strokeRoundedMoreHorizontal,
  );
  static const moreVerticalRounded = KapyIconData(
    0xE069,
    HugeIcons.strokeRoundedMoreVertical,
  );
  static const cameraOffOutlined = KapyIconData(
    0xE03F,
    HugeIcons.strokeRoundedCameraOff01,
  );
  static const noteAddRounded = KapyIconData(
    0xE040,
    HugeIcons.strokeRoundedNoteAdd,
  );
  static const noteOutlined = KapyIconData(
    0xE041,
    HugeIcons.strokeRoundedNote01,
  );
  static const notesRounded = KapyIconData(0xE042, HugeIcons.strokeRoundedNote);
  static const numbersRounded = KapyIconData(
    0xE043,
    HugeIcons.strokeRoundedTextNumberSign,
  );
  static const opacityRounded = KapyIconData(
    0xE044,
    HugeIcons.strokeRoundedDroplet,
  );
  static const openInFullRounded = KapyIconData(
    0xE045,
    HugeIcons.strokeRoundedMaximize01,
  );
  static const openExternalRounded = KapyIconData(
    0xE046,
    HugeIcons.strokeRoundedArrowUpRight01,
  );
  static const pauseRounded = KapyIconData(
    0xE047,
    HugeIcons.strokeRoundedPause,
  );
  static const peopleOutlined = KapyIconData(
    0xE048,
    HugeIcons.strokeRoundedUserGroup,
  );
  static const photoLibraryOutlined = KapyIconData(
    0xE049,
    HugeIcons.strokeRoundedImage02,
  );
  static const playRounded = KapyIconData(0xE04A, HugeIcons.strokeRoundedPlay);
  static const publicRounded = KapyIconData(
    0xE04B,
    HugeIcons.strokeRoundedGlobe02,
  );
  static const pinOutlined = KapyIconData(0xE04C, HugeIcons.strokeRoundedPin);
  static const pinRounded = KapyIconData(0xE04D, HugeIcons.strokeRoundedPin02);
  static const radioCheckedRounded = KapyIconData(
    0xE04E,
    HugeIcons.strokeRoundedRadioButton,
  );
  static const radioUncheckedRounded = KapyIconData(
    0xE04F,
    HugeIcons.strokeRoundedCircle,
  );
  static const refreshRounded = KapyIconData(
    0xE050,
    HugeIcons.strokeRoundedReload,
  );
  static const restoreRounded = KapyIconData(
    0xE051,
    HugeIcons.strokeRoundedWasteRestore,
  );
  static const scheduleRounded = KapyIconData(
    0xE052,
    HugeIcons.strokeRoundedClock01,
  );
  static const searchOffRounded = KapyIconData(
    0xE053,
    HugeIcons.strokeRoundedSearchRemove,
  );
  static const searchRounded = KapyIconData(
    0xE054,
    HugeIcons.strokeRoundedSearch01,
  );
  static const selectAllRounded = KapyIconData(
    0xE055,
    HugeIcons.strokeRoundedSelect02,
  );
  static const backupRestoreRounded = KapyIconData(
    0xE056,
    HugeIcons.strokeRoundedDatabaseRestore,
  );
  static const settingsOutlined = KapyIconData(
    0xE057,
    HugeIcons.strokeRoundedSettings01,
  );
  static const spellcheckRounded = KapyIconData(
    0xE058,
    HugeIcons.strokeRoundedTextCheck,
  );
  static const stopRounded = KapyIconData(0xE059, HugeIcons.strokeRoundedStop);
  static const subjectRounded = KapyIconData(
    0xE05A,
    HugeIcons.strokeRoundedLeftToRightListDash,
  );
  static const syncRounded = KapyIconData(
    0xE05B,
    HugeIcons.strokeRoundedArrowReloadHorizontal,
  );
  static const systemUpdateRounded = KapyIconData(
    0xE05C,
    HugeIcons.strokeRoundedDownloadSquare01,
  );
  static const tagRounded = KapyIconData(0xE05D, HugeIcons.strokeRoundedTag01);
  static const textFieldsRounded = KapyIconData(
    0xE05E,
    HugeIcons.strokeRoundedTextFont,
  );
  static const textFormatRounded = KapyIconData(
    0xE05F,
    HugeIcons.strokeRoundedText,
  );
  static const textureRounded = KapyIconData(
    0xE060,
    HugeIcons.strokeRoundedMaterialAndTexture,
  );
  static const translateRounded = KapyIconData(
    0xE061,
    HugeIcons.strokeRoundedTranslate,
  );
  static const tuneRounded = KapyIconData(
    0xE062,
    HugeIcons.strokeRoundedPreferenceHorizontal,
  );
  static const verifiedOutlined = KapyIconData(
    0xE063,
    HugeIcons.strokeRoundedCheckmarkBadge01,
  );
  static const viewColumnOutlined = KapyIconData(
    0xE064,
    HugeIcons.strokeRoundedLayout2Column,
  );
  static const viewSidebarOutlined = KapyIconData(
    0xE065,
    HugeIcons.strokeRoundedViewSidebarLeft,
  );
  static const visibilityOutlined = KapyIconData(
    0xE066,
    HugeIcons.strokeRoundedView,
  );
  static const warningRounded = KapyIconData(
    0xE067,
    HugeIcons.strokeRoundedAlert02,
  );
  static const wavingHandOutlined = KapyIconData(
    0xE068,
    HugeIcons.strokeRoundedWavingHand01,
  );
  static const videoOutlined = KapyIconData(
    0xE06B,
    HugeIcons.strokeRoundedVideo01,
  );
  static const tableRounded = KapyIconData(
    0xE06C,
    HugeIcons.strokeRoundedGridTable,
  );
  static const numberedListRounded = KapyIconData(
    0xE06D,
    HugeIcons.strokeRoundedLeftToRightListNumber,
  );
  static const quoteRounded = KapyIconData(
    0xE06E,
    HugeIcons.strokeRoundedQuoteDown,
  );
  static const dividerRounded = KapyIconData(
    0xE06F,
    HugeIcons.strokeRoundedMinusSign,
  );
  static const codeRounded = KapyIconData(0xE070, HugeIcons.strokeRoundedCode);
  static const tableRowAbove = KapyIconData(
    0xE071,
    HugeIcons.strokeRoundedInsertRowUp,
  );
  static const tableRowBelow = KapyIconData(
    0xE072,
    HugeIcons.strokeRoundedInsertRowDown,
  );
  static const tableColumnLeft = KapyIconData(
    0xE073,
    HugeIcons.strokeRoundedInsertColumnLeft,
  );
  static const tableColumnRight = KapyIconData(
    0xE074,
    HugeIcons.strokeRoundedInsertColumnRight,
  );
  static const tableDeleteRow = KapyIconData(
    0xE075,
    HugeIcons.strokeRoundedDeleteRow,
  );
  static const tableDeleteColumn = KapyIconData(
    0xE076,
    HugeIcons.strokeRoundedDeleteColumn,
  );
  static const alignLeft = KapyIconData(
    0xE077,
    HugeIcons.strokeRoundedTextAlignLeft,
  );
  static const alignCenter = KapyIconData(
    0xE078,
    HugeIcons.strokeRoundedTextAlignCenter,
  );
  static const alignRight = KapyIconData(
    0xE079,
    HugeIcons.strokeRoundedTextAlignRight,
  );
}
