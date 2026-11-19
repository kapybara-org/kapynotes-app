import 'apple_summarizer.dart';
import 'gemma_summarizer.dart';

/// Whether this platform can summarise on the device at all: Apple's model or
/// the downloaded one. Linux has neither, so its summaries are the cloud's or
/// none.
bool get deviceSummariesPossible =>
    AppleSummarizer.isPossibleHere || GemmaSummarizer.isPossibleHere;
