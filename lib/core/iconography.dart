import 'package:hugeicons/hugeicons.dart';
import 'package:material_ui/material_ui.dart';

/// The one icon language used by Kapy Notes.
///
/// Hugeicons ships its free stroke-rounded set as vector path data rather
/// than as an icon font. Keeping those paths behind this small semantic layer
/// gives the app one 1.5 px stroke, which a call site cannot change, and keeps
/// call sites independent from the package's generated names.
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
  });

  final KapyIconData icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;
  final TextDirection? textDirection;

  @override
  Widget build(BuildContext context) {
    Widget glyph = HugeIcon(
      icon: icon.paths,
      size: size,
      color: color,
      strokeWidth: 1.5,
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

/// Semantic app icons in Hugeicons' stroke-rounded family.
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
  static const removeRounded = KapyIconData(
    0xE0DD,
    HugeIcons.strokeRoundedRemove01,
  );

  /// The boards' plain archive box, drawn on Hugeicons' 24-unit
  /// stroke-rounded grid because the set has no lidded box without an arrow.
  static const archiveOutlined = KapyIconData(0xE090, [
    [
      'path',
      {
        'key': '0',
        'd':
            'M4.5 3H19.5C20.0523 3 20.5 3.44772 20.5 4V5.5C20.5 6.05228 20.0523 6.5 19.5 6.5H4.5C3.94772 6.5 3.5 6.05228 3.5 5.5V4C3.5 3.44772 3.94772 3 4.5 3Z',
        'stroke': 'currentColor',
        'strokeWidth': '1.5',
        'strokeLinecap': 'round',
        'strokeLinejoin': 'round',
      },
    ],
    [
      'path',
      {
        'key': '1',
        'd':
            'M4.5 6.5V18C4.5 19.6569 5.84315 21 7.5 21H16.5C18.1569 21 19.5 19.6569 19.5 18V6.5',
        'stroke': 'currentColor',
        'strokeWidth': '1.5',
        'strokeLinecap': 'round',
        'strokeLinejoin': 'round',
      },
    ],
    [
      'path',
      {
        'key': '2',
        'd': 'M10.5 11H13.5',
        'stroke': 'currentColor',
        'strokeWidth': '1.5',
        'strokeLinecap': 'round',
        'strokeLinejoin': 'round',
      },
    ],
  ]);
  static const arrowBackRounded = KapyIconData(
    0xE004,
    HugeIcons.strokeRoundedArrowLeft02,
  );
  static const brokenImageOutlined = KapyIconData(
    0xE00B,
    HugeIcons.strokeRoundedImageNotFound01,
  );
  static const calendarOutlined = KapyIconData(
    0xE00C,
    HugeIcons.strokeRoundedCalendar03,
  );
  static const calendarRemoveOutlined = KapyIconData(
    0xE0EA,
    HugeIcons.strokeRoundedCalendarMinus02,
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
  static const tasksOutlined = KapyIconData(
    0xE0DA,
    HugeIcons.strokeRoundedCheckmarkSquare02,
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
  static const chevronUpRounded = KapyIconData(
    0xE0E4,
    HugeIcons.strokeRoundedArrowUp01,
  );
  static const cutRounded = KapyIconData(
    0xE0E5,
    HugeIcons.strokeRoundedScissor01,
  );
  static const pasteRounded = KapyIconData(
    0xE0E6,
    HugeIcons.strokeRoundedClipboardPaste,
  );
  static const circleOutlined = KapyIconData(
    0xE015,
    HugeIcons.strokeRoundedCircle,
  );
  static const clipboardOutlined = KapyIconData(
    0xE0DC,
    HugeIcons.strokeRoundedClipboard,
  );
  static const closeRounded = KapyIconData(
    0xE016,
    HugeIcons.strokeRoundedCancel01,
  );
  static const cloudRounded = KapyIconData(
    0xE0D3,
    HugeIcons.strokeRoundedCloud,
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
  static const fireOutlined = KapyIconData(0xE091, HugeIcons.strokeRoundedFire);
  static const flagOutlined = KapyIconData(
    0xE025,
    HugeIcons.strokeRoundedFlag02,
  );
  static const folderOutlined = KapyIconData(
    0xE0E7,
    HugeIcons.strokeRoundedFolder01,
  );
  static const folderAddOutlined = KapyIconData(
    0xE0E8,
    HugeIcons.strokeRoundedFolderAdd,
  );
  static const folderMoveOutlined = KapyIconData(
    0xE0E9,
    HugeIcons.strokeRoundedFolderMoveTo,
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
    HugeIcons.strokeRoundedTextIndentLess,
  );
  static const indentIncreaseRounded = KapyIconData(
    0xE02A,
    HugeIcons.strokeRoundedTextIndentMore,
  );
  static const formatItalicRounded = KapyIconData(
    0xE02B,
    HugeIcons.strokeRoundedTextItalic,
  );
  static const bulletedListRounded = KapyIconData(
    0xE02C,
    HugeIcons.strokeRoundedLeftToRightListBullet,
  );
  static const homeOutlined = KapyIconData(
    0xE0EC,
    HugeIcons.strokeRoundedHome03,
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
  static const micRounded = KapyIconData(0xE03D, HugeIcons.strokeRoundedMic01);
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
  static const groupOutlined = KapyIconData(
    0xE092,
    HugeIcons.strokeRoundedUserMultiple,
  );
  static const filterRounded = KapyIconData(
    0xE0D0,
    HugeIcons.strokeRoundedFilterHorizontal,
  );
  static const layersRounded = KapyIconData(
    0xE0D5,
    HugeIcons.strokeRoundedLayers01,
  );
  static const listViewRounded = KapyIconData(
    0xE0D1,
    HugeIcons.strokeRoundedListView,
  );
  static const gridViewRounded = KapyIconData(
    0xE0D2,
    HugeIcons.strokeRoundedGridView,
  );
  static const photoLibraryOutlined = KapyIconData(
    0xE049,
    HugeIcons.strokeRoundedImage02,
  );
  static const playRounded = KapyIconData(0xE04A, HugeIcons.strokeRoundedPlay);
  static const pinOutlined = KapyIconData(0xE04C, HugeIcons.strokeRoundedPin);
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
  static const settingsOutlined = KapyIconData(
    0xE057,
    HugeIcons.strokeRoundedSettings01,
  );
  static const settingsGearOutlined = KapyIconData(
    0xE093,
    HugeIcons.strokeRoundedSettings02,
  );
  static const stopRounded = KapyIconData(0xE059, HugeIcons.strokeRoundedStop);
  static const systemUpdateRounded = KapyIconData(
    0xE05C,
    HugeIcons.strokeRoundedDownloadSquare01,
  );
  static const tagRounded = KapyIconData(0xE05D, HugeIcons.strokeRoundedTag01);
  static const textFormatRounded = KapyIconData(
    0xE05F,
    HugeIcons.strokeRoundedText,
  );
  static const viewColumnOutlined = KapyIconData(
    0xE064,
    HugeIcons.strokeRoundedLayout2Column,
  );
  static const visibilityOutlined = KapyIconData(
    0xE066,
    HugeIcons.strokeRoundedView,
  );
  static const warningRounded = KapyIconData(
    0xE067,
    HugeIcons.strokeRoundedAlert02,
  );
  static const attachFileRounded = KapyIconData(
    0xE071,
    HugeIcons.strokeRoundedAttachment01,
  );
  static const fileOutlined = KapyIconData(
    0xE072,
    HugeIcons.strokeRoundedFile01,
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
  static const heading1Rounded = KapyIconData(
    0xE0D6,
    HugeIcons.strokeRoundedHeading01,
  );
  static const heading2Rounded = KapyIconData(
    0xE0D7,
    HugeIcons.strokeRoundedHeading02,
  );
  static const heading3Rounded = KapyIconData(
    0xE0D8,
    HugeIcons.strokeRoundedHeading03,
  );
  static const formulaRounded = KapyIconData(
    0xE0D9,
    HugeIcons.strokeRoundedFunction,
  );
  static const strikethroughRounded = KapyIconData(
    0xE0DA,
    HugeIcons.strokeRoundedTextStrikethrough,
  );
  static const inlineCodeRounded = KapyIconData(
    0xE0DB,
    HugeIcons.strokeRoundedSourceCode,
  );
  static const infiniteRounded = KapyIconData(
    0xE0E7,
    HugeIcons.strokeRoundedInfinity01,
  );
  static const dividerRounded = KapyIconData(
    0xE06F,
    HugeIcons.strokeRoundedMinusSign,
  );
  static const codeRounded = KapyIconData(0xE070, HugeIcons.strokeRoundedCode);
  static const tableRowAbove = KapyIconData(
    0xE073,
    HugeIcons.strokeRoundedInsertRowUp,
  );
  static const tableRowBelow = KapyIconData(
    0xE074,
    HugeIcons.strokeRoundedInsertRowDown,
  );
  static const tableColumnLeft = KapyIconData(
    0xE075,
    HugeIcons.strokeRoundedInsertColumnLeft,
  );
  static const tableColumnRight = KapyIconData(
    0xE076,
    HugeIcons.strokeRoundedInsertColumnRight,
  );
  static const tableDeleteRow = KapyIconData(
    0xE077,
    HugeIcons.strokeRoundedDeleteRow,
  );
  static const tableDeleteColumn = KapyIconData(
    0xE078,
    HugeIcons.strokeRoundedDeleteColumn,
  );
  static const alignLeft = KapyIconData(
    0xE079,
    HugeIcons.strokeRoundedTextAlignLeft,
  );
  static const alignCenter = KapyIconData(
    0xE07A,
    HugeIcons.strokeRoundedTextAlignCenter,
  );
  static const alignRight = KapyIconData(
    0xE07B,
    HugeIcons.strokeRoundedTextAlignRight,
  );

  // The drawing canvas.
  static const selectRounded = KapyIconData(
    0xE07D,
    HugeIcons.strokeRoundedCursor02,
  );
  static const penRounded = KapyIconData(0xE07E, HugeIcons.strokeRoundedPencil);
  static const rectangleRounded = KapyIconData(
    0xE07F,
    HugeIcons.strokeRoundedSquare,
  );
  static const arrowRounded = KapyIconData(
    0xE080,
    HugeIcons.strokeRoundedArrowUpRight01,
  );
  static const lineRounded = KapyIconData(0xE081, HugeIcons.strokeRoundedLiner);
  static const eraserRounded = KapyIconData(
    0xE082,
    HugeIcons.strokeRoundedEraser,
  );
  static const undoRounded = KapyIconData(
    0xE083,
    HugeIcons.strokeRoundedUndo02,
  );
  static const sunsetRounded = KapyIconData(
    0xE0E8,
    HugeIcons.strokeRoundedSunset,
  );
  static const redoRounded = KapyIconData(
    0xE084,
    HugeIcons.strokeRoundedRedo02,
  );
  static const panRounded = KapyIconData(
    0xE085,
    HugeIcons.strokeRoundedHandGrab,
  );

  // The settings dialog's rail and General pane, as Riverbank draws them.
  static const paintBoardOutlined = KapyIconData(
    0xE0C0,
    HugeIcons.strokeRoundedPaintBoard,
  );
  static const commandOutlined = KapyIconData(
    0xE0C1,
    HugeIcons.strokeRoundedCommand,
  );
  static const refreshOutlined = KapyIconData(
    0xE0C2,
    HugeIcons.strokeRoundedRefresh,
  );
  static const computerOutlined = KapyIconData(
    0xE0C8,
    HugeIcons.strokeRoundedComputer,
  );
  static const sparklesOutlined = KapyIconData(
    0xE0DC,
    HugeIcons.strokeRoundedSparkles,
  );
  static const chatAddOutlined = KapyIconData(
    0xE0DD,
    HugeIcons.strokeRoundedBubbleChatAdd,
  );
  static const chatEditOutlined = KapyIconData(
    0xE0DE,
    HugeIcons.strokeRoundedBubbleChatEdit,
  );
  static const chatHistoryOutlined = KapyIconData(
    0xE0EB,
    HugeIcons.strokeRoundedTransactionHistory,
  );
  static const sendRounded = KapyIconData(
    0xE0DF,
    HugeIcons.strokeRoundedArrowUp02,
  );
  static const commandLineOutlined = KapyIconData(
    0xE0E0,
    HugeIcons.strokeRoundedCommandLine,
  );
  static const keyOutlined = KapyIconData(0xE0E1, HugeIcons.strokeRoundedKey01);
  static const wifiOffRounded = KapyIconData(
    0xE0E2,
    HugeIcons.strokeRoundedWifiOff01,
  );
  static const moreHorizontalRounded = KapyIconData(
    0xE0ED,
    HugeIcons.strokeRoundedMoreHorizontal,
  );
  static const forwardRounded = KapyIconData(
    0xE0EE,
    HugeIcons.strokeRoundedForward01,
  );
  static const pencilEditRounded = KapyIconData(
    0xE0EF,
    HugeIcons.strokeRoundedPencilEdit01,
  );
  static const slidersRounded = KapyIconData(
    0xE0F0,
    HugeIcons.strokeRoundedSlidersHorizontal,
  );
  static const messageQuestionRounded = KapyIconData(
    0xE0F1,
    HugeIcons.strokeRoundedMessageQuestion,
  );
}
