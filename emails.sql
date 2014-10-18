CREATE TABLE IF NOT EXISTS `emails` (
`id` int(11) NOT NULL,
  `email` varchar(65) NOT NULL,
  `messagequota` int(10) unsigned NOT NULL DEFAULT '0',
  `messagetally` int(10) unsigned NOT NULL DEFAULT '0',
  `timestamp` int(10) unsigned DEFAULT NULL
) ENGINE=InnoDB  DEFAULT CHARSET=latin1 AUTO_INCREMENT=2 ;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `emails`
--
ALTER TABLE `emails`
 ADD PRIMARY KEY (`id`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `emails`
--
ALTER TABLE `emails`
MODIFY `id` int(11) NOT NULL AUTO_INCREMENT,AUTO_INCREMENT=2;
