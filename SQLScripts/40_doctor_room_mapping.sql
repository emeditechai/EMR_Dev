/* 
    Schema Script for Room Doctor Assignment Feature
    Description: Creates the DoctorRoomMapping table to allow exclusively mapping a doctor to a room.
*/

IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'DoctorRoomMapping')
BEGIN
    CREATE TABLE DoctorRoomMapping (
        DoctorId INT NOT NULL,
        RoomId INT NOT NULL,
        CreatedBy INT NULL,
        CreatedDate DATETIME NOT NULL DEFAULT GETDATE(),
        
        -- Enforce DoctorId as the Primary Key so a doctor can only have 1 active room assignment
        PRIMARY KEY (DoctorId),
        
        -- Optional Foreign Keys (assuming Doctors and DoctorRoomMaster tables exist)
        -- CONSTRAINT FK_DoctorRoomMapping_Doctor FOREIGN KEY (DoctorId) REFERENCES Doctors(DoctorId),
        -- CONSTRAINT FK_DoctorRoomMapping_Room FOREIGN KEY (RoomId) REFERENCES DoctorRoomMaster(RoomId)
    );

    PRINT 'DoctorRoomMapping table created successfully.';
END
ELSE
BEGIN
    PRINT 'DoctorRoomMapping table already exists.';
END
GO
