
trait val ReportStatusCode
primitive BoundaryCountStatus is ReportStatusCode
primitive BoundaryStatus is ReportStatusCode

primitive ReportStatusCodeParser
  fun apply(s: String): ReportStatusCode ? =>
    match s
    | "boundary-count-status" => BoundaryCountStatus
    //!@
    | "boundary-status" => BoundaryStatus
    else
      error
    end
