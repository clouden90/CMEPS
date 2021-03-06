module med_time_mod

  use med_kind_mod        , only : CX=>SHR_KIND_CX, CS=>SHR_KIND_CS, CL=>SHR_KIND_CL, R8=>SHR_KIND_R8
  use ESMF                , only : ESMF_GridComp, ESMF_GridCompGet, ESMF_GridCompSet
  use ESMF                , only : ESMF_Clock, ESMF_ClockCreate, ESMF_ClockGet, ESMF_ClockSet
  use ESMF                , only : ESMF_ClockAdvance
  use ESMF                , only : ESMF_Alarm, ESMF_AlarmCreate, ESMF_AlarmGet
  use ESMF                , only : ESMF_Calendar, ESMF_CalKind_Flag, ESMF_CalendarCreate
  use ESMF                , only : ESMF_CALKIND_NOLEAP, ESMF_CALKIND_GREGORIAN
  use ESMF                , only : ESMF_Time, ESMF_TimeGet, ESMF_TimeSet
  use ESMF                , only : ESMF_TimeInterval, ESMF_TimeIntervalSet, ESMF_TimeIntervalGet
  use ESMF                , only : ESMF_SUCCESS, ESMF_LogWrite, ESMF_LOGMSG_INFO, ESMF_FAILURE
  use ESMF                , only : ESMF_VM, ESMF_VMGet, ESMF_VMBroadcast
  use ESMF                , only : ESMF_LOGMSG_INFO, ESMF_FAILURE
  use ESMF                , only : operator(<), operator(/=), operator(+)
  use ESMF                , only : operator(-), operator(*) , operator(>=)
  use ESMF                , only : operator(<=), operator(>), operator(==)
  use NUOPC               , only : NUOPC_CompAttributeGet
  use med_constants_mod   , only : dbug_flag => med_constants_dbug_flag
  use med_utils_mod       , only : chkerr => med_utils_ChkErr

  implicit none
  private    ! default private

  public  :: med_time_alarmInit  ! initialize an alarm

  ! Clock and alarm options
  character(len=*), private, parameter :: &
       optNONE           = "none"      , &
       optNever          = "never"     , &
       optNSteps         = "nsteps"    , &
       optNSeconds       = "nseconds"  , &
       optNMinutes       = "nminutes"  , &
       optNHours         = "nhours"    , &
       optNDays          = "ndays"     , &
       optNMonths        = "nmonths"   , &
       optNYears         = "nyears"    , &
       optMonthly        = "monthly"   , &
       optYearly         = "yearly"    , &
       optDate           = "date"      , &
       optGLCCouplingPeriod = "glc_coupling_period"

  ! Module data
  integer, parameter          :: SecPerDay = 86400 ! Seconds per day
  character(len=*), parameter :: u_FILE_u = &
       __FILE__

!===============================================================================
contains
!===============================================================================

  subroutine med_time_alarmInit( clock, alarm, option, &
       opt_n, opt_ymd, opt_tod, RefTime, alarmname, rc)

    ! Setup an alarm in a clock
    ! Notes: The ringtime sent to AlarmCreate MUST be the next alarm
    ! time.  If you send an arbitrary but proper ringtime from the
    ! past and the ring interval, the alarm will always go off on the
    ! next clock advance and this will cause serious problems.  Even
    ! if it makes sense to initialize an alarm with some reference
    ! time and the alarm interval, that reference time has to be
    ! advance forward to be >= the current time.  In the logic below
    ! we set an appropriate "NextAlarm" and then we make sure to
    ! advance it properly based on the ring interval.

    ! input/output variables
    type(ESMF_Clock)            , intent(inout) :: clock     ! clock
    type(ESMF_Alarm)            , intent(inout) :: alarm     ! alarm
    character(len=*)            , intent(in)    :: option    ! alarm option
    integer          , optional , intent(in)    :: opt_n     ! alarm freq
    integer          , optional , intent(in)    :: opt_ymd   ! alarm ymd
    integer          , optional , intent(in)    :: opt_tod   ! alarm tod (sec)
    type(ESMF_Time)  , optional , intent(in)    :: RefTime   ! ref time
    character(len=*) , optional , intent(in)    :: alarmname ! alarm name
    integer                     , intent(inout) :: rc        ! Return code

    ! local variables
    type(ESMF_Calendar)     :: cal              ! calendar
    integer                 :: lymd             ! local ymd
    integer                 :: ltod             ! local tod
    integer                 :: cyy,cmm,cdd,csec ! time info
    character(len=64)       :: lalarmname       ! local alarm name
    logical                 :: update_nextalarm ! update next alarm
    type(ESMF_Time)         :: CurrTime         ! Current Time
    type(ESMF_Time)         :: NextAlarm        ! Next restart alarm time
    type(ESMF_TimeInterval) :: AlarmInterval    ! Alarm interval
    integer                 :: sec
    character(len=*), parameter :: subname = '(med_time_alarmInit): '
    !-------------------------------------------------------------------------------

    rc = ESMF_SUCCESS

    lalarmname = 'alarm_unknown'
    if (present(alarmname)) lalarmname = trim(alarmname)
    ltod = 0
    if (present(opt_tod)) ltod = opt_tod
    lymd = -1
    if (present(opt_ymd)) lymd = opt_ymd

    call ESMF_ClockGet(clock, CurrTime=CurrTime, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_TimeGet(CurrTime, yy=cyy, mm=cmm, dd=cdd, s=csec, rc=rc )
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

    ! initial guess of next alarm, this will be updated below
    if (present(RefTime)) then
       NextAlarm = RefTime
    else
       NextAlarm = CurrTime
    endif

    ! Get calendar from clock
    call ESMF_ClockGet(clock, calendar=cal)

    ! Error checks
    if (trim(option) == optdate) then
       if (.not. present(opt_ymd)) then
          call ESMF_LogWrite(trim(subname)//trim(option)//' requires opt_ymd', ESMF_LOGMSG_INFO)
          rc = ESMF_FAILURE
          return
       end if
       if (lymd < 0 .or. ltod < 0) then
          call ESMF_LogWrite(subname//trim(option)//'opt_ymd, opt_tod invalid', ESMF_LOGMSG_INFO)
          rc = ESMF_FAILURE
          return
       end if
    else if (trim(option) == optNSteps   .or. &
             trim(option) == optNSeconds .or. &
             trim(option) == optNMinutes .or. &
             trim(option) == optNHours   .or. &
             trim(option) == optNDays    .or. &
             trim(option) == optNMonths  .or. &
             trim(option) == optNYears) then
       if (.not.present(opt_n)) then
          call ESMF_LogWrite(subname//trim(option)//' requires opt_n', ESMF_LOGMSG_INFO)
          rc = ESMF_FAILURE
          return
       end if
       if (opt_n <= 0) then
          call ESMF_LogWrite(subname//trim(option)//' invalid opt_n', ESMF_LOGMSG_INFO)
          rc = ESMF_FAILURE
          return
       end if
    end if

    ! Determine inputs for call to create alarm
    selectcase (trim(option))

    case (optNONE)
       call ESMF_TimeIntervalSet(AlarmInterval, yy=9999, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       call ESMF_TimeSet( NextAlarm, yy=9999, mm=12, dd=1, s=0, calendar=cal, rc=rc )
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       update_nextalarm  = .false.

    case (optNever)
       call ESMF_TimeIntervalSet(AlarmInterval, yy=9999, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       call ESMF_TimeSet( NextAlarm, yy=9999, mm=12, dd=1, s=0, calendar=cal, rc=rc )
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       update_nextalarm  = .false.

    case (optNSteps)
       call ESMF_ClockGet(clock, TimeStep=AlarmInterval, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       AlarmInterval = AlarmInterval * opt_n
       update_nextalarm  = .true.

    case (optNSeconds)
       call ESMF_TimeIntervalSet(AlarmInterval, s=1, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       AlarmInterval = AlarmInterval * opt_n
       update_nextalarm  = .true.

    case (optNMinutes)
       call ESMF_TimeIntervalSet(AlarmInterval, s=60, rc=rc)
       AlarmInterval = AlarmInterval * opt_n
       update_nextalarm  = .true.

    case (optNHours)
       call ESMF_TimeIntervalSet(AlarmInterval, s=3600, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       AlarmInterval = AlarmInterval * opt_n
       update_nextalarm  = .true.

    case (optNDays)
       call ESMF_TimeIntervalSet(AlarmInterval, d=1, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       AlarmInterval = AlarmInterval * opt_n
       update_nextalarm  = .true.

    case (optNMonths)
       call ESMF_TimeIntervalSet(AlarmInterval, mm=1, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       AlarmInterval = AlarmInterval * opt_n
       update_nextalarm  = .true.

    case (optMonthly)
       call ESMF_TimeIntervalSet(AlarmInterval, mm=1, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       call ESMF_TimeSet( NextAlarm, yy=cyy, mm=cmm, dd=1, s=0, calendar=cal, rc=rc )
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       update_nextalarm  = .true.

    case (optNYears)
       call ESMF_TimeIntervalSet(AlarmInterval, yy=1, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       AlarmInterval = AlarmInterval * opt_n
       update_nextalarm  = .true.

    case (optYearly)
       call ESMF_TimeIntervalSet(AlarmInterval, yy=1, rc=rc)
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       call ESMF_TimeSet( NextAlarm, yy=cyy, mm=1, dd=1, s=0, calendar=cal, rc=rc )
       if (ChkErr(rc,__LINE__,u_FILE_u)) return
       update_nextalarm  = .true.

    case default
       call ESMF_LogWrite(subname//'unknown option '//trim(option), ESMF_LOGMSG_INFO)
       rc = ESMF_FAILURE
       return

    end select

    ! --------------------------------------------------------------------------------
    ! --- AlarmInterval and NextAlarm should be set ---
    ! --------------------------------------------------------------------------------

    ! --- advance Next Alarm so it won't ring on first timestep for
    ! --- most options above. go back one alarminterval just to be careful

    if (update_nextalarm) then
       NextAlarm = NextAlarm - AlarmInterval
       do while (NextAlarm <= CurrTime)
          NextAlarm = NextAlarm + AlarmInterval
       enddo
    endif

    alarm = ESMF_AlarmCreate( name=lalarmname, clock=clock, ringTime=NextAlarm, &
         ringInterval=AlarmInterval, rc=rc)
    if (ChkErr(rc,__LINE__,u_FILE_u)) return

  end subroutine med_time_alarmInit

end module med_time_mod
