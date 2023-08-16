import NIOCore

struct ExtendedQueryStateMachine {

    private enum State {
        case initialized(ExtendedQueryContext)
        case describeInfoReceived(ExtendedQueryContext, DescribeInfo)
        case streaming(
            ExtendedQueryContext,
            DescribeInfo,
            OracleBackendMessage.RowHeader,
            RowStreamStateMachine
        )

        case commandComplete
        case error(OracleSQLError)

        case modifying
    }

    enum Action {
        case sendExecute(ExtendedQueryContext)
        case sendReexecute

        case succeedQuery(EventLoopPromise<OracleRowStream>, QueryResult)

        /// State indicating that the previous message contains more unconsumed data.
        case moreData(ExtendedQueryContext, ByteBuffer)
        case forwardRows([DataRow])
        case forwardStreamComplete([DataRow])
        /// Error payload and a optional cursor ID, which should be closed in a future roundtrip.
        case forwardStreamError(OracleSQLError, cursorID: UInt16?)

        case read
        case wait
    }

    private var state: State
    private var isCancelled: Bool

    init(queryContext: ExtendedQueryContext) {
        self.isCancelled = false
        self.state = .initialized(queryContext)
    }

    mutating func start() -> Action {
        guard case .initialized(let queryContext) = state else {
            preconditionFailure(
                "Start should only be called, if the query has been initialized"
            )
        }

        return .sendExecute(queryContext)
    }

    mutating func cancel() -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure(
                "Start must be called immediately after the query was created"
            )

        case .describeInfoReceived(let context, _):
            guard !self.isCancelled else {
                return .wait
            }

            self.isCancelled = true
            fatalError("todo")

        case .streaming(let context, _, _, let rows):
            precondition(!self.isCancelled)
            self.isCancelled = true

            fatalError("todo")

        case .commandComplete, .error:
            // the stream has already finished
            return .wait

        case .modifying:
            preconditionFailure("invalid state")
        }
    }

    mutating func describeInfoReceived(_ describeInfo: DescribeInfo) -> Action {
        guard case .initialized(let context) = state else {
            preconditionFailure("Describe info should be the initial response")
        }

        self.avoidingStateMachineCoW { state in
            state = .describeInfoReceived(context, describeInfo)
        }

        return .wait
    }

    mutating func rowHeaderReceived(
        _ rowHeader: OracleBackendMessage.RowHeader
    ) -> Action {
        guard case .describeInfoReceived(
            let context, let describeInfo
        ) = state else {
            preconditionFailure()
        }

        self.avoidingStateMachineCoW { state in
            state = .streaming(context, describeInfo, rowHeader, .init())
        }

        switch context.statement {
        case .ddl(let promise),
            .dml(let promise),
            .plsql(let promise),
            .query(let promise):
            return .succeedQuery(
                promise,
                QueryResult(value: describeInfo.columns, logger: context.logger)
            )
        }
    }

    mutating func rowDataReceived(
        _ rowData: OracleBackendMessage.RowData
    ) -> Action {
        var buffer = rowData.slice
        switch self.state {
        case .streaming(
            let context, let describeInfo, let rowHeader, var demandStateMachine
        ):
            let row = self.rowDataReceived(
                buffer: &buffer,
                describeInfo: describeInfo,
                rowHeader: rowHeader,
                rowIndex: 0 // todo: use current row index
            )

            demandStateMachine.receivedRow(row)
            self.avoidingStateMachineCoW { state in
                state = .streaming(
                    context, describeInfo, rowHeader, demandStateMachine
                )
            }

            return .moreData(context, buffer.slice())
        default:
            preconditionFailure()
        }
    }

    mutating func errorReceived(
        _ error: OracleBackendMessage.BackendError
    ) -> Action {

        let action: Action
        if
            Constants.TNS_ERR_NO_DATA_FOUND == error.number ||
            Constants.TNS_ERR_ARRAY_DML_ERRORS == error.number
        {
            switch self.state {
            case .initialized, .commandComplete, .error:
                preconditionFailure()
            case .describeInfoReceived(_, _):
                fatalError("is this possible?")

            case .streaming(_, _, _, var demandStateMachine):
                self.avoidingStateMachineCoW { state in
                    state = .commandComplete
                }

                let rows = demandStateMachine.channelReadComplete() ?? []
                action = .forwardStreamComplete(rows)

            case .modifying:
                preconditionFailure("invalid state")
            }
        } else if 
            error.number == Constants.TNS_ERR_VAR_NOT_IN_SELECT_LIST,
            let cursor = error.cursorID
        {
            self.avoidingStateMachineCoW { state in
                state = .error(.server(error))
            }

            action = .forwardStreamError(.server(error), cursorID: cursor)
        } else if
            let cursor = error.cursorID,
            error.number != 0 && cursor != 0
        {
            let exception = getExceptionClass(for: Int32(error.number))
            self.avoidingStateMachineCoW { state in
                state = .error(.server(error))
            }
            if exception != .integrityError {
                action = .forwardStreamError(.server(error), cursorID: cursor)
            } else {
                action = .forwardStreamError(.server(error), cursorID: nil)
            }
        } else {
            self.avoidingStateMachineCoW { state in
                state = .error(.server(error))
            }
            action = .forwardStreamError(.server(error), cursorID: nil)
        }

        return action
    }

    // MARK: Consumer Actions

    mutating func requestQueryRows() -> Action {
        switch self.state {
        case .streaming(
            let queryContext,
            let describeInfo,
            let rowHeader,
            var demandStateMachine
        ):
            return self.avoidingStateMachineCoW { state in
                let action = demandStateMachine.demandMoreResponseBodyParts()
                state = .streaming(
                    queryContext, describeInfo, rowHeader, demandStateMachine
                )
                switch action {
                case .read:
                    return .read
                case .wait:
                    return .wait
                }
            }

        case .initialized, .describeInfoReceived:
            preconditionFailure(
                "Requested to consume next row without anything going on."
            )

        case .commandComplete, .error:
            preconditionFailure("""
            The stream is already closed or in a failure state; \
            rows can not be consumed at this time.
            """)

        case .modifying:
            preconditionFailure("invalid state")
        }
    }

    // MARK: - Private helper methods -

    private func isDuplicateData(
        columnNumber: UInt32, bitVector: [UInt8]?
    ) -> Bool {
        guard let bitVector else { return false }
        let byteNumber = columnNumber / 8
        let bitNumber = columnNumber % 8
        return bitVector[Int(byteNumber)] & (1 << bitNumber) == 0
    }

    private func processColumnData(
        from buffer: inout ByteBuffer,
        columnInfo: DescribeInfo.Column
    ) -> ByteBuffer? {
        let oracleType = columnInfo.dataType.oracleType
        let csfrm = columnInfo.dataType.csfrm
        let bufferSize = columnInfo.bufferSize

        var columnValue: ByteBuffer?
        if bufferSize == 0 && ![.long, .longRAW, .uRowID].contains(oracleType) {
            columnValue = nil
        } else if [.varchar, .char, .long].contains(oracleType) {
            if csfrm == Constants.TNS_CS_NCHAR {
                fatalError() // TODO: check ncharsetid
            }
            columnValue = buffer.readStringSlice(with: Int(csfrm))
        } else if [.raw, .longRAW].contains(oracleType) {
            columnValue = buffer.readOracleSlice()
        } else if oracleType == .number {
            columnValue = buffer.readOracleSlice()
        } else if [.date, .timestamp, .timestampLTZ, .timestampTZ]
            .contains(oracleType) {
            columnValue = buffer.readOracleSlice()
        } else if oracleType == .rowID {
            columnValue = buffer.readOracleSlice()
        } else if oracleType == .binaryDouble {
            columnValue = buffer.readOracleSlice()
        } else if oracleType == .binaryFloat {
            columnValue = buffer.readOracleSlice()
        } else if oracleType == .binaryInteger {
            columnValue = buffer.readOracleSlice()
        } else if oracleType == .cursor {
            fatalError("not implemented")
        } else if oracleType == .boolean {
            columnValue = buffer.readOracleSlice()
        } else if oracleType == .intervalDS {
            columnValue = buffer.readOracleSlice()
        } else if [.clob, .blob].contains(oracleType) {
            fatalError("not implemented")
        } else if oracleType == .json {
            fatalError("not implemented")
        } else {
            fatalError("not implemented")
        }

        return columnValue
    }

    private mutating func rowDataReceived(
        buffer: inout ByteBuffer,
        describeInfo: DescribeInfo,
        rowHeader: OracleBackendMessage.RowHeader,
        rowIndex: Int
    ) -> DataRow {
        var out = ByteBuffer()
        for (index, column) in describeInfo.columns.enumerated() {
            if self.isDuplicateData(
                columnNumber: UInt32(index), bitVector: rowHeader.bitVector
            ) {
                if rowIndex == 0 {
                    preconditionFailure()
                } else {
                    // TODO: get value from previous row
                    fatalError()
                }
            } else if var data = self.processColumnData(
                from: &buffer, columnInfo: column
            ) {
                out.writeBuffer(&data)
            }
        }

        let data = DataRow(
            columnCount: describeInfo.columns.count, bytes: out
        )

        return data
    }

    var isComplete: Bool {
        switch self.state {
        case .initialized, .describeInfoReceived, .streaming:
            return false
        case .commandComplete, .error:
            return true

        case .modifying:
            preconditionFailure("invalid state")
        }
    }
}

extension ExtendedQueryStateMachine {
    /// While the state machine logic above is great, there is a downside to having all of the state machine
    /// data in associated data on enumerations: any modification of that data will trigger copy on write
    /// for heap-allocated data. That means that for _every operation on the state machine_ we will CoW
    /// our underlying state, which is not good.
    ///
    /// The way we can avoid this is by using this helper function. It will temporarily set state to a value with
    /// no associated data, before attempting the body of the function. It will also verify that the state
    /// machine never remains in this bad state.
    ///
    /// A key note here is that all callers must ensure that they return to a good state before they exit.
    ///
    /// Sadly, because it's generic and has a closure, we need to force it to be inlined at all call sites,
    /// which is not idea.
    @inline(__always)
    private mutating func avoidingStateMachineCoW<ReturnType>(
        _ body: (inout State) -> ReturnType
    ) -> ReturnType {
        self.state = .modifying
        defer {
            assert(!self.isModifying)
        }

        return body(&self.state)
    }

    private var isModifying: Bool {
        if case .modifying = self.state {
            return true
        } else {
            return false
        }
    }
}
