
trait val ReportStatusCode
primitive FinishedAcksStatus is ReportStatusCode
primitive BoundaryCountStatus is ReportStatusCode
//!@
primitive RequestsStatus is ReportStatusCode

primitive ReportStatusCodeParser
  fun apply(s: String): ReportStatusCode ? =>
    match s
    | "finished-acks-status" => FinishedAcksStatus
    | "boundary-count-status" => BoundaryCountStatus
    | "requests-status" => RequestsStatus
    else
      error
    end
